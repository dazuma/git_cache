# Release History

### v0.2.0 / 2026-10-06

* FIXED: Raise GitCache::Error when the cache directory cannot be created
* FIXED: Move repo locks out of the directories they protect
* FIXED: Store cache data in a format version subdirectory of custom cache dirs
* FIXED: Write repo state atomically
* FIXED: Record the remote even if the first get fails
* FIXED: Do not mask a failed operation's error with a state write error

### v0.1.2 / 2026-08-20

* FIXED: Prevent git auto maintenance from racing with cache removals

### v0.1.1 / 2026-05-05

* BREAKING CHANGE: Make GitCache.sources_writable? private for now

### v0.1.0 / 2026-05-04

* ADDED: Initial extraction from toys-core
