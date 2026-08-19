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

The cache directory (default: `<XDG_CACHE_HOME>/git-cache/v1`) contains one subdirectory per remote, named by `Digest::MD5.hexdigest(remote)`. Inside each remote's directory:

- `repo.lock` — JSON state file *and* OS-level exclusive flock for all mutations of this remote. Schema is documented inline above the `RepoLock` class. Holds `remote`, per-ref `{sha, updated, accessed}`, and per-source `{sha → path → {accessed}}` entries.
- `repo/` — a single bare-ish working clone of the remote. Commits are fetched shallowly (`--depth=1`) into local refs named `git-cache/<original-ref>`, so every requested commit/branch/tag becomes its own local ref.
- `<sha>/` — one directory per cached commit SHA, holding shared, *read-only* materialized source trees. Files inside are `chmod a-w` unless `GIT_CACHE_WRITABLE` is set (the env var exists for environments like temp-dir cleanup that can't handle read-only files).

### Key flows in `GitCache#get`

1. `ensure_repo_base_dir` creates `<cache_dir>/<md5(remote)>/`.
2. `lock_repo` opens `repo.lock`, takes an exclusive flock, parses the JSON state into a `RepoLock`, yields it, and writes back if `modified?` is true. **All mutating operations must run inside this block.**
3. `ensure_repo` validates `repo/` actually points at the requested remote — if not, it nukes and re-inits the clone with the new origin. This is what makes hash collisions across remotes recoverable (and what makes destroying `repo/` on remote mismatch acceptable).
4. `ensure_commit` fetches the requested ref into `git-cache/<ref>` if absent or stale (the `update:` parameter accepts `true`/`false`/seconds — staleness is computed from `RepoLock#ref_stale?`). SHAs (validated by length 40 or 64 hex) are never refetched.
5. Output mode:
   - `into:` provided → `copy_files` does a `git switch --detach <sha>` in `repo/` and recursively copies into the user's directory, skipping `.git` only when the requested path is the repo root.
   - `into:` omitted → `ensure_source` populates `<sha>/<path>` once and returns it as a *shared* read-only path. Subsequent calls for the same `(sha, path)` reuse it. The shared-source contract is "do not mutate," and that's enforced via filesystem permissions.

### Path safety

`GitCache.normalize_path` (class method) strips leading slashes, collapses `//`, resolves `.`/`..`, raises `ArgumentError` on traversal past root, and rejects any path whose first segment is `.git`. All caller-supplied paths flow through it, and joins use `safe_join` (which preserves `.` as "the directory itself" rather than appending it).

### Concurrency model

A single `repo.lock` flock per remote serializes all writers for that remote across processes. Readers of shared sources don't take the lock and rely on the read-only permission bits to detect tampering only by convention. The lock is held for the duration of any `GitCache#get` call, including the `git fetch`, so concurrent calls to the same remote will serialize on the network operation.

Every git invocation goes through the `git` helper, which injects `-c maintenance.auto=false`. Do not bypass it. Since git 2.47, `git fetch` ends by spawning `git maintenance run --auto --detach`, which keeps writing into `repo/.git/objects` *after* the fetch has returned — outside anything the flock protects, and racing with the cache's own traversals and removals. `gc.auto=0` is not a substitute: it only suppresses that spawn as of git 2.55. See issue #5.

### Removal APIs

All directory removal goes through the private `remove_dir`, which renames the directory to a `.trash-<random>` sibling before deleting it. The rename is atomic and unaffected by concurrent writes inside the tree, so the cache entry is gone for clients even if the delete can't finish; leftovers are invisible (nothing enumerates cache directories — `remotes` skips dot-prefixed children and requires a `repo.lock`, and `RepoInfo` reads only the lock JSON) and get swept by later removals. It falls back to an in-place retry loop where rename fails (Windows), and raises `GitCache::Error` if the directory survives both.

`chmod_R u+w` before deleting defeats the read-only protection on shared sources, but must go through `chmod_recursive`: `FileUtils.chmod_R`'s `force:` guards only the chmod of each entry, not the traversal that finds them, so an entry vanishing mid-walk raises regardless of it. `remove_sources` also garbage-collects the per-SHA directory once its last source entry is dropped.

## Repository conventions

- `lib/git_cache.rb` holds the `GitCache` class itself; value objects and internals live in `lib/git_cache/`. Resist splitting the main class further without a clear reason; the gemspec globs `lib/**/*.rb`, so additions ship automatically.
- The gemspec deliberately excludes `CLAUDE.md` and `AGENTS.md` from the packaged gem.
- Yardoc runs with `fail_on_warning` and `fail_on_undocumented_objects` — every public method/class/attribute needs a yard comment, and `@private` is the marker for internals (used heavily on `RepoLock`).
- Rubocop config is in `.rubocop.yml`; respect it before committing.
- The `.toys/` directory holds toys tool definitions and uses `toys-ci`. `.toys/.toys.rb` is the entrypoint; `.toys/ci.rb` defines the `ci` aggregate.
- Releases are driven by `toys-release` (`.toys/release.rb`, config in `.toys/.data/releases.yml`). `CHANGELOG.md` is *generated* from conventional commit messages — do not hand-edit it. Use conventional prefixes (`fix:`, `feat:`, `chore:`, `!` or `BREAKING CHANGE:` for breaks) and reference issues with a `Fixes #N` trailer.
- CI (`.github/workflows/ci.yml`) runs the matrix on ubuntu, macos, *and windows*, across Ruby 2.7-4.0 plus JRuby and TruffleRuby. Tests must be portable: Windows ignores POSIX directory permission bits and refuses to rename or delete directories with open handles inside, so permission- or handle-dependent tests need `skip` guards (see "raises if a repo cannot be removed").
