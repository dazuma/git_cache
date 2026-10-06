# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

`git_cache` is a Ruby gem (`GitCache` class) that provides cached local-filesystem access to remote git data. Given a remote, path, and commit, it materializes the files locally and caches them so repeated requests don't hit the network.

The gem depends on `exec_service` (subprocess execution) and `simple_xdg` (XDG cache dir resolution). Required Ruby is `>= 2.7`.

## Commands

The build/test/lint workflow is driven by [toys](https://dazuma.github.io/toys). After `gem install toys`:

- `toys ci` — full CI suite: bundle install, rubocop, tests, yardoc, gem build
- `toys ci --update` — same, but `bundle update --all` first
- `toys ci --integration` — include integration tests (which actually clone from GitHub)
- `toys test` — run unit tests only (skips integration)
- `toys test --integration` — run all tests including integration (sets `TEST_INTEGRATION=true`)
- `toys test test/test_git_cache.rb` — run tests in a specific test file
- `toys test -n /pattern/` — run tests with names matching the given pattern
- `toys rubocop` — run rubocop
- `toys yardoc` — build yard docs (fails on warnings or undocumented objects)
- `toys build` — build the gem into `pkg/`

Integration tests are gated on `ENV["TEST_INTEGRATION"]`. They will hit `github.com` and clone real repositories.

Per global instructions, run affected tests and rubocop before committing.

## Architecture

The public surface is the `GitCache` class plus three value objects (`RepoInfo`, `RefInfo`, `SourceInfo`) and one error class (`GitCache::Error`, which carries the failing `ExecService::Result`).

### Cache layout on disk

The cache directory (default: `<XDG_CACHE_HOME>/git-cache/v2`; the `v2` is `FORMAT_VERSION`, bumped on incompatible layout changes) contains two subdirectories. Each remote is identified by `<md5>` = `GitCache.remote_dir_name(remote)` = `Digest::MD5.hexdigest(remote)`.

- `locks/<md5>.lock` — an empty file that is only the target of the OS-level exclusive flock for all mutations of this remote. It lives *outside* the tree it protects and is **never deleted** (see "Concurrency model").
- `repos/<md5>/` — the remote's base dir (`RepoInfo#base_dir`). Removing it removes the remote from the cache.

Inside each base dir:

- `state.json` — the JSON state, read and written only under the flock. Schema is documented inline above the `RepoLock` class. Holds `remote`, per-ref `{sha, updated, accessed}`, and per-source `{sha → path → {accessed}}` entries. It deliberately lives *inside* the base dir so that one atomic rename removes data and state together.
- `repo/` — a single bare-ish working clone of the remote. Commits are fetched shallowly (`--depth=1`) into local refs named `git-cache/<original-ref>`, so every requested commit/branch/tag becomes its own local ref.
- `<sha>/` — one directory per cached commit SHA, holding shared, *read-only* materialized source trees. Files inside are `chmod a-w` unless `GIT_CACHE_WRITABLE` is set (the env var exists for environments like temp-dir cleanup that can't handle read-only files).

### Key flows in `GitCache#get`

1. `lock_repo(name, ..., create: true)` takes the flock (via the lock-only primitive `flock_repo`), *then* creates `repos/<md5>/` inside the lock — so a concurrent `remove_repos` can't rename it between creation and locking. It parses `state.json` into a `RepoLock`, yields it, and writes back if `modified?` is true. **All mutating operations must run inside this block.** Without `create:`, `lock_repo` returns `nil` without yielding if the base dir is gone (e.g. removed while waiting for the lock).
2. `ensure_repo` validates `repo/` actually points at the requested remote — if not, it nukes and re-inits the clone with the new origin. This is what makes hash collisions across remotes recoverable (and what makes destroying `repo/` on remote mismatch acceptable).
3. `ensure_commit` fetches the requested ref into `git-cache/<ref>` if absent or stale (the `update:` parameter accepts `true`/`false`/seconds — staleness is computed from `RepoLock#ref_stale?`). SHAs (validated by length 40 or 64 hex) are never refetched.
4. Output mode:
   - `into:` provided → `copy_files` does a `git switch --detach <sha>` in `repo/` and recursively copies into the user's directory, skipping `.git` only when the requested path is the repo root.
   - `into:` omitted → `ensure_source` populates `<sha>/<path>` once and returns it as a *shared* read-only path. Subsequent calls for the same `(sha, path)` reuse it. The shared-source contract is "do not mutate," and that's enforced via filesystem permissions.

### Path safety

`GitCache.normalize_path` (class method) strips leading slashes, collapses `//`, resolves `.`/`..`, raises `ArgumentError` on traversal past root, and rejects any path whose first segment is `.git`. All caller-supplied paths flow through it, and joins use `safe_join` (which preserves `.` as "the directory itself" rather than appending it).

### Concurrency model

A single flock on `locks/<md5>.lock` per remote serializes all writers for that remote across processes, including `remove_repos`, which waits for any in-flight `get`. Readers of shared sources don't take the lock and rely on the read-only permission bits to detect tampering only by convention. The lock is held for the duration of any `GitCache#get` call, including the `git fetch`, so concurrent calls to the same remote will serialize on the network operation.

**Never delete lock files**, and never move the lock back inside `repos/<md5>/`. A flock belongs to the inode, and clients find the lock by opening the path with `File::CREAT`. If the file is deleted (directly, or by removing/renaming the directory containing it), the next client mints a new inode and "acquires" it while an older client still holds the lock on the old one, so the lock silently stops excluding anyone (issue #6). Safe deletion (re-checking the inode after locking) isn't portable to Windows. The cost — one empty file per remote ever cached — is accepted. Keeping the lock handle outside the base dir also lets `remove_repos` rename the base dir while holding the lock on Windows, which refuses to rename directories with open handles inside.

`repo_info`, `remove_refs`, `remove_sources`, and `remove_repos` first do a cheap unlocked `File.directory?` check so that asking about an uncached remote creates nothing (not even a lock file), then re-check under the lock.

Every git invocation goes through the `git` helper, which injects `-c maintenance.auto=false`. Do not bypass it. Since git 2.47, `git fetch` ends by spawning `git maintenance run --auto --detach`, which keeps writing into `repo/.git/objects` *after* the fetch has returned — outside anything the flock protects, and racing with the cache's own traversals and removals. `gc.auto=0` is not a substitute: it only suppresses that spawn as of git 2.55. See issue #5.

### Removal APIs

All directory removal goes through the private `remove_dir`, which renames the directory to a `.trash-<random>` sibling before deleting it. The rename is atomic and unaffected by concurrent writes inside the tree, so the cache entry is gone for clients even if the delete can't finish; leftovers are invisible (nothing enumerates cache directories — `remotes` lists only `repos/`, skips dot-prefixed children, and requires a `state.json`, and `RepoInfo` reads only the state JSON) and get swept by later removals. It falls back to an in-place retry loop where rename fails (Windows), and raises `GitCache::Error` if the directory survives both. `remove_repos` holds the remote's flock across `remove_dir(base_dir)`, so its trash lands in `repos/.trash-*`; `ensure_repo` and `remove_sources` leave theirs inside the base dir.

`chmod_R u+w` before deleting defeats the read-only protection on shared sources, but must go through `chmod_recursive`: `FileUtils.chmod_R`'s `force:` guards only the chmod of each entry, not the traversal that finds them, so an entry vanishing mid-walk raises regardless of it. `remove_sources` also garbage-collects the per-SHA directory once its last source entry is dropped.

## Repository conventions

- `lib/git_cache.rb` holds the `GitCache` class itself; value objects and internals live in `lib/git_cache/`. Resist splitting the main class further without a clear reason; the gemspec globs `lib/**/*.rb`, so additions ship automatically.
- The gemspec deliberately excludes `CLAUDE.md` and `AGENTS.md` from the packaged gem.
- Yardoc runs with `fail_on_warning` and `fail_on_undocumented_objects` — every public method/class/attribute needs a yard comment, and `@private` is the marker for internals (used heavily on `RepoLock`).
- Rubocop config is in `.rubocop.yml`; respect it before committing.
- The `.toys/` directory holds toys tool definitions and uses `toys-ci`. `.toys/.toys.rb` is the entrypoint; `.toys/ci.rb` defines the `ci` aggregate.
- Releases are driven by `toys-release` (`.toys/release.rb`, config in `.toys/.data/releases.yml`). `CHANGELOG.md` is *generated* from conventional commit messages — do not hand-edit it. Use conventional prefixes (`fix:`, `feat:`, `chore:`, `!` or `BREAKING CHANGE:` for breaks) and reference issues with a `Fixes #N` trailer.
- CI (`.github/workflows/ci.yml`) runs the matrix on ubuntu, macos, *and windows*, across Ruby 2.7-4.0 plus JRuby and TruffleRuby. Tests must be portable: Windows ignores POSIX directory permission bits and refuses to rename or delete directories with open handles inside, so permission- or handle-dependent tests need `skip` guards (see "raises if a repo cannot be removed").

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `dazuma/git_cache` (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` plus `docs/adr/` at the repo root (both created lazily). See `docs/agents/domain.md`.
