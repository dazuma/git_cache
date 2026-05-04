# GitCache

The `GitCache` class provides cached access to remote git data. Given a remote
repository, a path, and a commit, it makes the files from that repository
available in the local file system. Access is cached, so repeated requests for
the same commit and path in the same repo do not make additional network calls.

## Getting started

Install `GitCache` via the
[git_cache gem](https://rubygems.org/gems/git_cache).

```sh
% gem install git_cache
```

or add it to your Gemfile:

```ruby
gem "git_cache"
```

To use the service, instantiate `GitCache`, and call the `get` method to access
files from a repository, pulling them from the remote if necessary:

```ruby
require "git_cache"
git_cache = GitCache.new
readme_path = git_cache.get("https://github.com/dazuma/git_cache.git",
                            path: "README.md")
puts File.read(readme_path)
```

## Contributing

Development is done in GitHub at https://github.com/dazuma/git_cache.

 *  To file issues: https://github.com/dazuma/git_cache/issues.
 *  For questions and discussion, please do not file an issue. Instead, use the
    discussions feature: https://github.com/dazuma/git_cache/discussions.
 *  Pull requests are welcome, but in general please open an issue first before
    contributing significant changes.

The library uses [toys](https://dazuma.github.io/toys) for testing and CI. To
run the test suite, `gem install toys` and then run `toys ci`. You can also run
unit tests, rubocop, and build tests independently.

## License

Copyright 2026 Daniel Azuma

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
IN THE SOFTWARE.
