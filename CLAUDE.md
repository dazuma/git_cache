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

### Removal APIs

`remove_repos`, `remove_refs`, and `remove_sources` all `chmod_R u+w` before `rm_rf` to defeat the read-only protection. `remove_sources` also garbage-collects the per-SHA directory once its last source entry is dropped.

## Repository conventions

- Single-file library — resist the urge to split `lib/git_cache.rb` into multiple files without a clear reason; the gemspec globs `lib/**/*.rb` so additions ship automatically.
- The gemspec deliberately excludes `CLAUDE.md` and `AGENTS.md` from the packaged gem.
- Yardoc runs with `fail_on_warning` and `fail_on_undocumented_objects` — every public method/class/attribute needs a yard comment, and `@private` is the marker for internals (used heavily on `RepoLock`).
- Rubocop config is in `.rubocop.yml`; respect it before committing.
- The `.toys/` directory holds toys tool definitions and uses `toys-ci`. `.toys/.toys.rb` is the entrypoint; `.toys/ci.rb` defines the `ci` aggregate.
