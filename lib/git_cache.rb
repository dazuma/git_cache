# frozen_string_literal: true

require "git_cache/error"
require "git_cache/repo_info"
require "git_cache/repo_state"

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
  #     a specific directory in the user's XDG cache. Cache data is stored
  #     in a subdirectory named for the cache format version, so that clients
  #     using incompatible formats can share a cache directory safely.
  #
  def initialize(cache_dir: nil)
    require "digest"
    require "fileutils"
    require "json"
    require "securerandom"
    require "exec_service"
    @using_default_cache_dir = cache_dir.nil?
    @cache_dir = ::File.expand_path(cache_dir || default_cache_dir)
    @data_dir = ::File.join(@cache_dir, FORMAT_VERSION)
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
    name = ::GitCache.remote_dir_name(remote)
    dir = repo_base_dir_for(name)
    lock_repo(name, remote, timestamp, create: true) do |repo_state|
      ensure_repo(dir, remote)
      sha = ensure_commit(dir, commit, repo_state, update)
      if into
        copy_files(dir, sha, path, repo_state, into)
      else
        ensure_source(dir, sha, path, repo_state)
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
    repos_dir = ::File.join(@data_dir, REPOS_DIR_NAME)
    return result unless ::File.directory?(repos_dir)
    ::Dir.children(repos_dir).each do |name|
      next if name.start_with?(".")
      next unless ::File.file?(::File.join(repos_dir, name, STATE_FILE_NAME))
      remote = lock_repo(name, &:remote)
      result << remote if remote
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
    name = ::GitCache.remote_dir_name(remote)
    dir = repo_base_dir_for(name)
    return nil unless ::File.directory?(dir)
    lock_repo(name, remote) do |repo_state|
      RepoInfo.new(dir, repo_state.data)
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
  # This waits for any in-progress {#get} calls for these repos to finish.
  # However, be careful not to remove repos whose shared sources are
  # currently in use by other GitCache clients.
  #
  # @param remotes [Array<String>,:all,nil] The remotes to remove. If set
  #     to :all or nil, removes all repos.
  # @return [Array<String>] The remotes actually removed.
  #
  def remove_repos(remotes)
    remotes = self.remotes if remotes.nil? || remotes == :all
    Array(remotes).map do |remote|
      name = ::GitCache.remote_dir_name(remote)
      dir = repo_base_dir_for(name)
      next unless ::File.directory?(dir)
      # Take the lock so we wait for any in-flight operation on this repo.
      # The lock file lives outside the directory being removed, so it keeps
      # excluding later clients after the removal.
      flock_repo(name) do
        next unless ::File.directory?(dir)
        remove_dir(dir)
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
    name = ::GitCache.remote_dir_name(remote)
    return nil unless ::File.directory?(repo_base_dir_for(name))
    lock_repo(name, remote) do |repo_state|
      results = []
      refs = repo_state.refs if refs.nil? || refs == :all
      Array(refs).each do |ref|
        ref_data = repo_state.delete_ref!(ref)
        results << RefInfo.new(ref, ref_data) if ref_data
      end
      results.sort
    end
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
    name = ::GitCache.remote_dir_name(remote)
    dir = repo_base_dir_for(name)
    return nil unless ::File.directory?(dir)
    lock_repo(name, remote) do |repo_state|
      results = []
      commits = nil if commits == :all
      shas = Array(commits).map { |ref| repo_state.lookup_ref(ref) }.compact.uniq if commits
      repo_state.find_sources(shas: shas).each do |(sha, path)|
        data = repo_state.delete_source!(sha, path)
        results << SourceInfo.new(dir, sha, path, data)
      end
      results.map(&:sha).uniq.each do |sha|
        unless repo_state.source_exists?(sha)
          remove_dir(::File.join(dir, sha))
        end
      end
      results.sort
    end
  end

  private

  # Cache layout, relative to the cache directory:
  #
  #     <FORMAT_VERSION>/       Data dir. Bumping FORMAT_VERSION on
  #                             incompatible layout changes isolates clients
  #                             using different formats.
  #       locks/<name>.lock     Lock file for the repo. Empty; used only as a
  #                             flock target. Never deleted (see flock_repo).
  #       repos/<name>/         Base dir for the repo. Removing it (via a
  #                             rename) removes the repo from the cache.
  #         state.json          Repo state (see RepoState).
  #         repo/               Working clone of the remote.
  #         <sha>/              Shared sources for a commit.
  #
  # where <name> is the remote_dir_name of the remote.
  #
  FORMAT_VERSION = "v2"
  LOCKS_DIR_NAME = "locks"
  REPOS_DIR_NAME = "repos"
  LOCK_FILE_SUFFIX = ".lock"
  STATE_FILE_NAME = "state.json"
  REPO_DIR_NAME = "repo"
  TRASH_DIR_PREFIX = ".trash-"

  # Config applied to every git invocation. Auto maintenance would otherwise
  # spawn a detached `git maintenance run --auto` process after each fetch,
  # which keeps writing into the cache repo after the fetch has returned, and
  # thus races with our own traversals and removals of that directory. These
  # are managed cache repos that we recreate at will, so background repacking
  # buys them nothing. Requires git 2.30 or later; older gits ignore config
  # keys they do not recognize.
  GIT_CONFIG_ARGS = ["-c", "maintenance.auto=false"].freeze

  private_constant :FORMAT_VERSION, :LOCKS_DIR_NAME, :REPOS_DIR_NAME,
                   :LOCK_FILE_SUFFIX, :STATE_FILE_NAME, :REPO_DIR_NAME,
                   :TRASH_DIR_PREFIX, :GIT_CONFIG_ARGS

  # Takes the remote_dir_name of a remote
  def repo_base_dir_for(name)
    ::File.join(@data_dir, REPOS_DIR_NAME, name)
  end

  # Takes the remote_dir_name of a remote
  def repo_lock_path_for(name)
    ::File.join(@data_dir, LOCKS_DIR_NAME, "#{name}#{LOCK_FILE_SUFFIX}")
  end

  def default_cache_dir
    require "simple_xdg"
    ::File.join(::SimpleXDG.new.cache_home, "git-cache")
  end

  def git(dir, cmd, error_message: nil)
    result = @exec.exec(["git"] + GIT_CONFIG_ARGS + cmd, chdir: dir)
    if !result.success? && error_message
      raise ::GitCache::Error.new(error_message, result)
    end
    result
  end

  # Removes a directory from the cache.
  #
  # The directory is first renamed out of the way, which is atomic and thus
  # unaffected by any concurrent writes happening inside it, so the cache
  # entry is gone as far as any client is concerned as soon as this returns.
  # Only then is the renamed copy deleted, best effort. Anything left behind
  # is invisible to clients and is swept up by later removals.
  #
  # Raises {GitCache::Error} if the directory could not be removed at all.
  #
  def remove_dir(dir)
    return unless ::File.exist?(dir)
    parent = ::File.dirname(dir)
    begin
      ::File.rename(dir, ::File.join(parent, "#{TRASH_DIR_PREFIX}#{::SecureRandom.hex(8)}"))
    rescue ::SystemCallError
      # Some filesystems (notably on Windows) refuse to rename a directory
      # that has open handles under it. Fall back to deleting in place.
      unless remove_dir_in_place(dir)
        raise ::GitCache::Error, "Unable to remove directory: #{dir}"
      end
    end
    sweep_trash(parent)
  end

  # Deletes a directory in place, retrying because a concurrent writer can
  # defeat a single pass. Returns whether the directory is gone.
  #
  def remove_dir_in_place(dir, attempts: 3)
    attempts.times do
      chmod_recursive("u+w", dir)
      ::FileUtils.rm_rf(dir)
      return true unless ::File.exist?(dir)
    end
    false
  end

  # Recursive chmod that tolerates entries disappearing while it runs. The
  # force: option of FileUtils.chmod_R covers only the chmod of each entry,
  # not the traversal that finds them, so a concurrent writer removing a
  # directory mid-walk raises out of chmod_R despite it.
  #
  def chmod_recursive(mode, dir)
    ::FileUtils.chmod_R(mode, dir, force: true)
  rescue ::SystemCallError
    nil
  end

  # Deletes any leftover trash directories in the given directory. Failures
  # are ignored; the leftovers are harmless and we can try again next time.
  #
  def sweep_trash(dir)
    ::Dir.children(dir).each do |child|
      remove_dir_in_place(::File.join(dir, child)) if child.start_with?(TRASH_DIR_PREFIX)
    end
  rescue ::SystemCallError
    nil
  end

  def ensure_cache_subdir(dir)
    ::FileUtils.mkdir_p(dir)
  rescue ::SystemCallError => e
    message = "Unable to create git cache directory #{dir}: #{e.message}"
    message += ". Set XDG_CACHE_HOME to a writable directory." if @using_default_cache_dir
    raise Error, message
  end

  # Takes an exclusive lock on the given repo for the duration of the block,
  # and returns the value of the block. Takes the remote_dir_name of a remote.
  #
  # The lock file lives outside the repo's base dir, so that removing the
  # base dir does not also remove the lock. Lock files must never be deleted:
  # a flock belongs to an inode, so if the file were deleted, a newcomer
  # would create a new one and "acquire" it while an older client still
  # holds the lock on the old one.
  #
  def flock_repo(name)
    lock_path = repo_lock_path_for(name)
    ensure_cache_subdir(::File.dirname(lock_path))
    ::File.open(lock_path, ::File::RDWR | ::File::CREAT) do |file|
      file.flock(::File::LOCK_EX)
      yield
    end
  end

  # Takes an exclusive lock on the given repo, and yields its state as a
  # {RepoState}, writing the state back afterward if it was modified. Returns
  # the value of the block. Takes the remote_dir_name of a remote.
  #
  # If create is true, creates the repo's base dir if it does not exist.
  # Otherwise, if the base dir does not exist (e.g. because it was removed
  # while we were waiting for the lock), returns nil without yielding.
  #
  def lock_repo(name, remote = nil, timestamp = nil, create: false)
    flock_repo(name) do
      dir = repo_base_dir_for(name)
      if create
        ensure_cache_subdir(dir)
      elsif !::File.directory?(dir)
        next nil
      end
      state_path = ::File.join(dir, STATE_FILE_NAME)
      content = ::File.file?(state_path) ? ::File.read(state_path) : ""
      repo_state = RepoState.new(content, remote, timestamp)
      begin
        yield repo_state
      ensure
        ::File.write(state_path, repo_state.dump) if repo_state.modified?
      end
    end
  end

  def ensure_repo(dir, remote)
    repo_dir = ::File.join(dir, REPO_DIR_NAME)
    ::FileUtils.mkdir_p(repo_dir)
    result = git(repo_dir, ["remote", "get-url", "origin"])
    unless result.success? && result.captured_out.strip == remote
      remove_dir(repo_dir)
      ::FileUtils.mkdir_p(repo_dir)
      git(repo_dir, ["init"],
          error_message: "Unable to initialize git repository")
      git(repo_dir, ["remote", "add", "origin", remote],
          error_message: "Unable to add git remote: #{remote}")
    end
  end

  def ensure_commit(dir, commit, repo_state, update = false)
    local_commit = "git-cache/#{commit}"
    repo_dir = ::File.join(dir, REPO_DIR_NAME)
    is_sha = ::GitCache.valid_sha?(commit)
    update = repo_state.ref_stale?(commit, update) unless is_sha
    if (update && !is_sha) || !commit_exists?(repo_dir, local_commit)
      git(repo_dir, ["fetch", "--depth=1", "--force", "origin", "#{commit}:#{local_commit}"],
          error_message: "Unable to fetch commit: #{commit}")
      repo_state.update_ref!(commit)
    end
    result = git(repo_dir, ["rev-parse", local_commit],
                 error_message: "Unable to retrieve commit: #{local_commit}")
    sha = result.captured_out.strip
    repo_state.access_ref!(commit, sha)
    sha
  end

  def commit_exists?(repo_dir, commit)
    result = git(repo_dir, ["cat-file", "-t", commit])
    result.success? && result.captured_out.strip == "commit"
  end

  def ensure_source(dir, sha, path, repo_state)
    repo_path = ::File.join(dir, REPO_DIR_NAME)
    source_path = ::File.join(dir, sha)
    result =
      if repo_state.source_exists?(sha, path)
        ::GitCache.safe_join(source_path, path)
      else
        chmod_recursive("u+w", source_path)
        begin
          copy_from_repo(repo_path, source_path, sha, path)
        ensure
          chmod_recursive("a-w", source_path) unless ::GitCache.sources_writable?
        end
      end
    repo_state.access_source!(sha, path)
    result
  end

  def copy_files(dir, sha, path, repo_state, into)
    repo_path = ::File.join(dir, REPO_DIR_NAME)
    result = copy_from_repo(repo_path, into, sha, path)
    repo_state.access_repo!
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
