# frozen_string_literal: true

class GitCache
  ##
  # Information about a remote git repository in the cache.
  #
  # This object is returned from {GitCache#repo_info}.
  #
  class RepoInfo
    include ::Comparable

    ##
    # The base directory of this git repository's cache entry. This
    # directory contains all cached data related to this repo. Deleting it
    # effectively removes the repo from the cache.
    #
    # @return [String]
    #
    attr_reader :base_dir

    ##
    # The git remote, usually a file system path or URL.
    #
    # @return [String]
    #
    attr_reader :remote

    ##
    # The last time any cached data from this repo was accessed, or `nil`
    # if the information is unavailable.
    #
    # @return [Time,nil]
    #
    attr_reader :last_accessed

    ##
    # A list of git refs (branches, tags, shas) that have been accessed
    # from this repo.
    #
    # @param ref [String,nil] If provided, return only entries matching
    #     this ref name. If omitted, return all entries.
    # @return [Array<RefInfo>]
    #
    def refs(ref: nil)
      return @refs.dup if ref.nil?
      @refs.find_all { |elem| elem.ref == ref }
    end

    ##
    # A list of shared source files and directories accessed for this repo.
    #
    # @param sha [String,nil] If provided, return only entries matching
    #     this SHA. If omitted, entries for all SHAs are included.
    # @param git_path [String,nil] If provided, return only entries
    #     matching this git path. If omitted, entries for all paths are
    #     included.
    # @return [Array<SourceInfo>]
    #
    def sources(sha: nil, git_path: nil)
      return @sources.dup if sha.nil? && git_path.nil?
      @sources.find_all do |elem|
        (sha.nil? || elem.sha == sha) &&
          (git_path.nil? || elem.git_path == git_path)
      end
    end

    ##
    # Convert this RepoInfo to a hash suitable for JSON output
    #
    # @return [Hash]
    #
    def to_h
      result = {
        "remote" => remote,
        "base_dir" => base_dir,
      }
      result["last_accessed"] = last_accessed.to_i if last_accessed
      result["refs"] = refs.map(&:to_h)
      result["sources"] = sources.map(&:to_h)
      result
    end

    ##
    # Comparison function
    #
    # @param other [RepoInfo]
    # @return [Integer]
    #
    def <=>(other)
      remote <=> other.remote
    end

    ##
    # @private
    #
    def initialize(base_dir, data)
      @base_dir = base_dir
      @remote = data["remote"]
      accessed = data["accessed"]
      @last_accessed = accessed ? ::Time.at(accessed).utc : nil
      @refs = (data["refs"] || {}).map { |ref, ref_data| RefInfo.new(ref, ref_data) }
      @sources = (data["sources"] || {}).flat_map do |sha, sha_data|
        sha_data.map do |path, path_data|
          SourceInfo.new(base_dir, sha, path, path_data)
        end
      end
      @refs.sort!
      @sources.sort!
    end
  end

  ##
  # Information about a git ref used in a cache.
  #
  class RefInfo
    include ::Comparable

    ##
    # The git ref
    #
    # @return [String]
    #
    attr_reader :ref

    ##
    # The git sha last associated with the ref
    #
    # @return [String]
    #
    attr_reader :sha

    ##
    # The timestamp when this ref was last accessed
    #
    # @return [Time,nil]
    #
    attr_reader :last_accessed

    ##
    # The timestamp when this ref was last updated
    #
    # @return [Time,nil]
    #
    attr_reader :last_updated

    ##
    # Convert this RefInfo to a hash suitable for JSON output
    #
    # @return [Hash]
    #
    def to_h
      result = {
        "ref" => ref,
        "sha" => sha,
      }
      result["last_accessed"] = last_accessed.to_i if last_accessed
      result["last_updated"] = last_updated.to_i if last_updated
      result
    end

    ##
    # Comparison function
    #
    # @param other [RefInfo]
    # @return [Integer]
    #
    def <=>(other)
      ref <=> other.ref
    end

    ##
    # @private
    #
    def initialize(ref, ref_data)
      @ref = ref
      @sha = ref_data["sha"]
      @last_accessed = ref_data["accessed"]
      @last_accessed = ::Time.at(@last_accessed).utc if @last_accessed
      @last_updated = ref_data["updated"]
      @last_updated = ::Time.at(@last_updated).utc if @last_updated
    end
  end

  ##
  # Information about shared source files provided from the cache.
  #
  class SourceInfo
    include ::Comparable

    ##
    # The git sha the source comes from
    #
    # @return [String]
    #
    attr_reader :sha

    ##
    # The path within the git repo
    #
    # @return [String]
    #
    attr_reader :git_path

    ##
    # The path to the source file or directory
    #
    # @return [String]
    #
    attr_reader :source

    ##
    # The timestamp when this ref was last accessed
    #
    # @return [Time,nil]
    #
    attr_reader :last_accessed

    ##
    # Convert this SourceInfo to a hash suitable for JSON output
    #
    # @return [Hash]
    #
    def to_h
      result = {
        "sha" => sha,
        "git_path" => git_path,
        "source" => source,
      }
      result["last_accessed"] = last_accessed.to_i if last_accessed
      result
    end

    ##
    # Comparison function
    #
    # @param other [SourceInfo]
    # @return [Integer]
    #
    def <=>(other)
      result = sha <=> other.sha
      result.zero? ? git_path <=> other.git_path : result
    end

    ##
    # @private
    #
    def initialize(base_dir, sha, git_path, path_data)
      @sha = sha
      @git_path = git_path
      root_dir = ::File.join(base_dir, sha)
      @source = ::GitCache.safe_join(root_dir, git_path)
      @last_accessed = path_data["accessed"]
      @last_accessed = @last_accessed ? ::Time.at(@last_accessed).utc : nil
    end
  end
end
