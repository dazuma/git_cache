# frozen_string_literal: true

lib = ::File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "git_cache/version"

::Gem::Specification.new do |spec|
  spec.name = "git_cache"
  spec.version = ::GitCache::VERSION
  spec.authors = ["Daniel Azuma"]
  spec.email = ["dazuma@gmail.com"]

  spec.summary = "A local file system cache of data from git repositories."
  spec.description =
    "The GitCache class provides cached access to remote git data. Given a" \
    " remote repository, a path, and a commit, it makes the files from that" \
    " repository available in the local file system. Access is cached, so" \
    " repeated requests for the same commit and path in the same repo do not" \
    " make additional network calls."
  spec.license = "MIT"
  spec.homepage = "https://github.com/dazuma/git_cache"

  spec.files = ::Dir.glob("lib/**/*.rb") +
               (::Dir.glob("*.md") - ["CLAUDE.md", "AGENTS.md"]) +
               [".yardopts"]
  spec.require_paths = ["lib"]

  spec.add_dependency "exec_service", "~> 0.1"
  spec.add_dependency "simple_xdg", "~> 0.1"
  spec.required_ruby_version = ">= 2.7"

  spec.metadata["bug_tracker_uri"] = "https://github.com/dazuma/git_cache/issues"
  spec.metadata["changelog_uri"] = "https://rubydoc.info/gems/git_cache/#{::GitCache::VERSION}/file/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "https://rubydoc.info/gems/git_cache/#{::GitCache::VERSION}"
  spec.metadata["homepage_uri"] = "https://github.com/dazuma/git_cache"
end
