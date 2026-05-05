# frozen_string_literal: true

require "git_cache/error"
require "git_cache/repo_info"
require "git_cache/repo_lock"

##
# This object provides cached access to remote git data. Given a remote
# repository, a path, and a commit, it makes the files available in the
# local filesystem. Access is cached, so repeated requests for the same
# commit and path in the same repo do not hit the remote repository again.
#
class GitCache
  ##
  # Access a git cache.
  #
  # @param cache_dir [String] The path to the cache directory. Defaults to
  #     a specific directory in the user's XDG cache.
  #
  def initialize(cache_dir: nil)
    require "digest"
    require "fileutils"
    require "json"
    require "exec_service"
    @cache_dir = ::File.expand_path(cache_dir || default_cache_dir)
    @exec = ::ExecService.new(out: :capture, err: :capture)
  end

  ##
  # The cache directory.
  #
  # @return [String]
  #
  attr_reader :cache_dir

  ##
  # Get the given git-based files from the git cache, loading from the
  # remote repo if necessary.
  #
  # The resulting files are either copied into a directory you provide in
  # the `:into` parameter, or populated into a _shared_ source directory if
  # you omit the `:into` parameter. In the latter case, it is important
  # that you do not modify the returned files or directories, nor add or
  # remove any files from the directories returned, to avoid confusing
  # callers that could be given the same directory. If you need to make any
  # modifications to the returned files, use `:into` to provide your own
  # private directory.
  #
  # @param remote [String] The URL of the git repo. Required.
  # @param path [String] The path to the file or directory within the repo.
  #     Optional. Defaults to the entire repo.
  # @param commit [String] The commit reference, which may be a SHA or any
  #     git ref such as a branch or tag. Optional. Defaults to `HEAD`.
  # @param into [String] If provided, copies the specified files into the
  #     given directory path. If omitted or `nil`, populates and returns a
  #     shared source file or directory.
  # @param update [boolean,Integer] Whether to update non-SHA commit
  #     references if they were previously loaded. This is useful, for
  #     example, if the commit is `HEAD` or a branch name. Pass `true` or
  #     `false` to specify whether to update, or an integer to update if
  #     last update was done at least that many seconds ago. Default is
  #     `false`.
  # @param timestamp [Integer,nil] The timestamp for recording the access
  #     time and determining whether a resource is stale. Normally, you
  #     should leave this out and it will default to the current time.
  #
  # @return [String] The full path to the cached files. The returned path
  #     will correspond to the path given. For example, if you provide the
  #     path `Gemfile` representing a single file in the repository, the
  #     returned path will point directly to the cached copy of that file.
  #
  def get(remote, path: nil, commit: nil, into: nil, update: false, timestamp: nil)
    path = ::GitCache.normalize_path(path)
    commit ||= "HEAD"
    timestamp ||= ::Time.now.to_i
    dir = ensure_repo_base_dir(remote)
    lock_repo(dir, remote, timestamp) do |repo_lock|
      ensure_repo(dir, remote)
      sha = ensure_commit(dir, commit, repo_lock, update)
      if into
        copy_files(dir, sha, path, repo_lock, into)
      else
        ensure_source(dir, sha, path, repo_lock)
      end
    end
  end
  alias find get

  ##
  # Returns an array of the known remote names.
  #
  # @return [Array<String>]
  #
  def remotes
    result = []
    return result unless ::File.directory?(cache_dir)
    ::Dir.entries(cache_dir).each do |child|
      next if child.start_with?(".")
      dir = ::File.join(cache_dir, child)
      if ::File.file?(::File.join(dir, LOCK_FILE_NAME))
        remote = lock_repo(dir, &:remote)
        result << remote if remote
      end
    end
    result.sort
  end

  ##
  # Returns a {RepoInfo} describing the cache for the given remote, or
  # `nil` if the given remote has never been cached.
  #
  # @param remote [String] Remote name for a repo
  # @return [RepoInfo,nil]
  #
  def repo_info(remote)
    dir = repo_base_dir_for(remote)
    return nil unless ::File.directory?(dir)
    lock_repo(dir, remote) do |repo_lock|
      RepoInfo.new(dir, repo_lock.data)
    end
  end

  ##
  # Removes caches for the given repos, or all repos if specified.
  #
  # Removes all cache information for the specified repositories, including
  # local clones and shared source directories. The next time these
  # repositories are requested, they will be reloaded from the remote
  # repository from scratch.
  #
  # Be careful not to remove repos that are currently in use by other
  # GitCache clients.
  #
  # @param remotes [Array<String>,:all,nil] The remotes to remove. If set
  #     to :all or nil, removes all repos.
  # @return [Array<String>] The remotes actually removed.
  #
  def remove_repos(remotes)
    remotes = self.remotes if remotes.nil? || remotes == :all
    Array(remotes).map do |remote|
      dir = repo_base_dir_for(remote)
      if ::File.directory?(dir)
        ::FileUtils.chmod_R("u+w", dir, force: true)
        ::FileUtils.rm_rf(dir)
        remote
      end
    end.compact.sort
  end

  ##
  # Remove records of the given refs (i.e. branches, tags, or `HEAD`) from
  # the given repository's cache. The next time those refs are requested,
  # they will be pulled from the remote repo.
  #
  # If you provide the `refs:` argument, only those refs are removed.
  # Otherwise, all refs are removed.
  #
  # @param remote [String] The repository
  # @param refs [Array<String>] The refs to remove. Optional.
  # @return [Array<RefInfo>,nil] The refs actually forgotten, or `nil` if
  #     the given repo is not in the cache.
  #
  def remove_refs(remote, refs: nil)
    dir = repo_base_dir_for(remote)
    return nil unless ::File.directory?(dir)
    results = []
    lock_repo(dir, remote) do |repo_lock|
      refs = repo_lock.refs if refs.nil? || refs == :all
      Array(refs).each do |ref|
        ref_data = repo_lock.delete_ref!(ref)
        results << RefInfo.new(ref, ref_data) if ref_data
      end
    end
    results.sort
  end

  ##
  # Removes shared sources for the given cache. The next time a client
  # requests them, the removed sources will be recopied from the repo.
  #
  # If you provide the `commits:` argument, only sources associated with
  # those commits are removed. Otherwise, all sources are removed.
  #
  # Be careful not to remove sources that are currently in use by other
  # GitCache clients.
  #
  # @param remote [String] The repository
  # @param commits [Array<String>] Remove only the sources for the given
  #     commits. Optional.
  # @return [Array<SourceInfo>,nil] The sources actually removed, or `nil`
  #     if the given repo is not in the cache.
  #
  def remove_sources(remote, commits: nil)
    dir = repo_base_dir_for(remote)
    return nil unless ::File.directory?(dir)
    results = []
    lock_repo(dir, remote) do |repo_lock|
      commits = nil if commits == :all
      shas = Array(commits).map { |ref| repo_lock.lookup_ref(ref) }.compact.uniq if commits
      repo_lock.find_sources(shas: shas).each do |(sha, path)|
        data = repo_lock.delete_source!(sha, path)
        results << SourceInfo.new(dir, sha, path, data)
      end
      results.map(&:sha).uniq.each do |sha|
        unless repo_lock.source_exists?(sha)
          sha_dir = ::File.join(dir, sha)
          ::FileUtils.chmod_R("u+w", sha_dir, force: true)
          ::FileUtils.rm_rf(sha_dir)
        end
      end
    end
    results.sort
  end

  private

  FORMAT_VERSION = "v1"
  REPO_DIR_NAME = "repo"
  LOCK_FILE_NAME = "repo.lock"
  private_constant :REPO_DIR_NAME, :LOCK_FILE_NAME, :FORMAT_VERSION

  def repo_base_dir_for(remote)
    ::File.join(@cache_dir, ::GitCache.remote_dir_name(remote))
  end

  def default_cache_dir
    require "simple_xdg"
    ::File.join(::SimpleXDG.new.cache_home, "git-cache", FORMAT_VERSION)
  end

  def git(dir, cmd, error_message: nil)
    result = @exec.exec(["git"] + cmd, chdir: dir)
    if !result.success? && error_message
      raise ::GitCache::Error.new(error_message, result)
    end
    result
  end

  def ensure_repo_base_dir(remote)
    dir = repo_base_dir_for(remote)
    ::FileUtils.mkdir_p(dir)
    dir
  end

  def lock_repo(dir, remote = nil, timestamp = nil)
    lock_path = ::File.join(dir, LOCK_FILE_NAME)
    ::File.open(lock_path, ::File::RDWR | ::File::CREAT) do |file|
      file.flock(::File::LOCK_EX)
      file.rewind
      repo_lock = RepoLock.new(file, remote, timestamp)
      begin
        yield repo_lock
      ensure
        if repo_lock.modified?
          file.rewind
          file.truncate(0)
          repo_lock.dump(file)
        end
      end
    end
  end

  def ensure_repo(dir, remote)
    repo_dir = ::File.join(dir, REPO_DIR_NAME)
    ::FileUtils.mkdir_p(repo_dir)
    result = git(repo_dir, ["remote", "get-url", "origin"])
    unless result.success? && result.captured_out.strip == remote
      ::FileUtils.chmod_R("u+w", repo_dir, force: true)
      ::FileUtils.rm_rf(repo_dir)
      ::FileUtils.mkdir_p(repo_dir)
      git(repo_dir, ["init"],
          error_message: "Unable to initialize git repository")
      git(repo_dir, ["remote", "add", "origin", remote],
          error_message: "Unable to add git remote: #{remote}")
    end
  end

  def ensure_commit(dir, commit, repo_lock, update = false)
    local_commit = "git-cache/#{commit}"
    repo_dir = ::File.join(dir, REPO_DIR_NAME)
    is_sha = ::GitCache.valid_sha?(commit)
    update = repo_lock.ref_stale?(commit, update) unless is_sha
    if (update && !is_sha) || !commit_exists?(repo_dir, local_commit)
      git(repo_dir, ["fetch", "--depth=1", "--force", "origin", "#{commit}:#{local_commit}"],
          error_message: "Unable to fetch commit: #{commit}")
      repo_lock.update_ref!(commit)
    end
    result = git(repo_dir, ["rev-parse", local_commit],
                 error_message: "Unable to retrieve commit: #{local_commit}")
    sha = result.captured_out.strip
    repo_lock.access_ref!(commit, sha)
    sha
  end

  def commit_exists?(repo_dir, commit)
    result = git(repo_dir, ["cat-file", "-t", commit])
    result.success? && result.captured_out.strip == "commit"
  end

  def ensure_source(dir, sha, path, repo_lock)
    repo_path = ::File.join(dir, REPO_DIR_NAME)
    source_path = ::File.join(dir, sha)
    result =
      if repo_lock.source_exists?(sha, path)
        ::GitCache.safe_join(source_path, path)
      else
        ::FileUtils.chmod_R("u+w", source_path, force: true)
        begin
          copy_from_repo(repo_path, source_path, sha, path)
        ensure
          ::FileUtils.chmod_R("a-w", source_path, force: true) unless ::GitCache.sources_writable?
        end
      end
    repo_lock.access_source!(sha, path)
    result
  end

  def copy_files(dir, sha, path, repo_lock, into)
    repo_path = ::File.join(dir, REPO_DIR_NAME)
    result = copy_from_repo(repo_path, into, sha, path)
    repo_lock.access_repo!
    result
  end

  def copy_from_repo(repo_dir, into, sha, path)
    git(repo_dir, ["switch", "--detach", sha],
        error_message: "Unable to switch to SHA #{sha}")
    repo_path = ::GitCache.safe_join(repo_dir, path)
    unless ::File.exist?(repo_path)
      raise Error, "Path #{path.inspect} does not exist at SHA #{sha}"
    end
    into_path = ::GitCache.safe_join(into, path)
    if path == "."
      ::FileUtils.mkdir_p(into)
    else
      ::FileUtils.mkdir_p(::File.dirname(into_path))
    end
    copy_recursive(repo_path, into_path, is_root: path == ".")
    into_path
  end

  def copy_recursive(from_path, to_path, is_root: false)
    from_stat = safe_stat(from_path)
    to_stat = safe_stat(to_path)
    if to_stat && from_stat
      if from_stat.directory? && to_stat.directory?
        ::Dir.children(from_path).each do |child|
          next if child == ".git" && is_root
          copy_recursive(::File.join(from_path, child), ::File.join(to_path, child))
        end
      else
        ::FileUtils.rm_rf(to_path)
        ::FileUtils.copy_entry(from_path, to_path)
      end
    elsif to_stat
      ::FileUtils.rm_rf(to_path)
    elsif from_stat
      ::FileUtils.copy_entry(from_path, to_path)
    end
  end

  def safe_stat(path)
    ::File.lstat(path)
  rescue ::SystemCallError
    nil
  end

  class << self
    ##
    # @private
    # Returns whether shared source files are writable by default.
    # Normally, shared sources are made read-only to protect them from being
    # modified accidentally since multiple clients may be accessing them.
    # However, you can disable this feature by setting the environment
    # variable `GIT_CACHE_WRITABLE` to any non-empty value. This can be
    # useful in environments that want to clean up temporary directories and
    # are being hindered by read-only files.
    #
    # @return [boolean]
    #
    def sources_writable?
      !::ENV["GIT_CACHE_WRITABLE"].to_s.empty?
    end

    ##
    # @private
    # Whether a given ref is a valid SHA-1 or SHA-256
    #
    # @param ref [String]
    # @return [boolean]
    #
    def valid_sha?(ref)
      /^[0-9a-f]+$/.match?(ref) && [40, 64].include?(ref.size)
    end

    ##
    # @private
    # Adds a path element to an existing path, handling the case where the
    # new path element is ".".
    #
    # @param dir [String]
    # @param path [String]
    # @return [String]
    #
    def safe_join(dir, path)
      path == "." ? dir : ::File.join(dir, path)
    end

    ##
    # @private
    #
    def remote_dir_name(remote)
      ::Digest::MD5.hexdigest(remote)
    end

    ##
    # @private
    #
    def normalize_path(orig_path)
      segs = []
      orig_segs = orig_path.to_s.sub(%r{^/+}, "").split(%r{/+})
      orig_segs.each do |seg|
        if seg == ".."
          raise ::ArgumentError, "Path #{orig_path.inspect} references its parent" if segs.empty?
          segs.pop
        elsif seg != "."
          segs.push(seg)
        end
      end
      raise ::ArgumentError, "Path #{orig_path.inspect} reads .git directory" if segs.first == ".git"
      segs.empty? ? "." : segs.join("/")
    end
  end
end
