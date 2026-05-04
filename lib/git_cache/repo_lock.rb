# frozen_string_literal: true

class GitCache
  ##
  # Associated with each repo (remote) is a lock file that saves the status
  # of the cache, and also serves as a file system lock for updates to the
  # repo. This is handled by the lock_repo method.
  #
  # This object represents the state of the repo, and is made available to
  # the block passed to lock_repo. It has the following schema:
  #
  #     remote: (String)           # the remote url
  #     accessed: (Integer)        # last accessed timestamp
  #     refs:
  #       (String):                # git ref
  #         sha: (String)          # resolved sha
  #         updated: (Integer)     # last updated timestamp
  #         accessed: (Integer)    # last accessed timestamp
  #     sources:
  #       (String):                # sha of the shared source
  #         (String):              # path populated
  #           accessed: (Integer)  # last accessed timestamp
  #
  # @private
  #
  class RepoLock
    ##
    # @private
    #
    def initialize(io, remote, timestamp)
      @data = ::JSON.parse(io.read) rescue {} # rubocop:disable Style/RescueModifier
      @data["remote"] ||= remote
      @data["refs"] ||= {}
      @data["sources"] ||= {}
      @modified = false
      @timestamp = timestamp || ::Time.now.to_i
    end

    ##
    # @private
    #
    attr_reader :data

    ##
    # @private
    #
    def modified?
      @modified
    end

    ##
    # @private
    #
    def dump(io)
      ::JSON.dump(@data, io)
    end

    ##
    # @private
    #
    def remote
      @data["remote"]
    end

    ##
    # @private
    #
    def refs
      @data["refs"].keys
    end

    ##
    # @private
    #
    def lookup_ref(ref)
      return ref if ::GitCache.valid_sha?(ref)
      @data["refs"][ref]&.fetch("sha", nil)
    end

    ##
    # @private
    #
    def ref_data(ref)
      @data["refs"][ref]
    end

    ##
    # @private
    #
    def ref_stale?(ref, age)
      ref_info = @data["refs"][ref]
      last_updated = ref_info ? ref_info.fetch("updated", 0) : 0
      return true if last_updated.zero?
      return age unless age.is_a?(::Numeric)
      @timestamp >= last_updated + age
    end

    ##
    # @private
    #
    def source_exists?(sha, path = nil)
      sha_info = @data["sources"][sha]
      return false if sha_info.nil?
      return true if path.nil?
      sha_info.key?(path) || sha_info.key?(".") ||
        sha_info.keys.any? { |existing_path| path.start_with?("#{existing_path}/") }
    end

    ##
    # @private
    #
    def source_data(sha, path)
      @data["sources"][sha]&.fetch(path, nil)
    end

    ##
    # @private
    #
    def find_sources(paths: nil, shas: nil)
      results = []
      @data["sources"].each do |sha, sha_data|
        next unless shas.nil? || shas.include?(sha)
        sha_data.each_key do |path|
          next unless paths.nil? || paths.include?(path)
          results << [sha, path]
        end
      end
      results
    end

    ##
    # @private
    #
    def access_repo!
      is_first = !@data.key?("accessed")
      @data["accessed"] = @timestamp
      @modified = true
      is_first
    end

    ##
    # @private
    #
    def access_ref!(ref, sha)
      ref_info = @data["refs"][ref] ||= {}
      ref_info["sha"] = sha
      is_first = !ref_info.key?("accessed")
      ref_info["accessed"] = @timestamp
      @modified = true
      is_first
    end

    ##
    # @private
    #
    def update_ref!(ref)
      ref_info = @data["refs"][ref] ||= {}
      is_first = !ref_info.key?("updated")
      ref_info["updated"] = @timestamp
      @modified = true
      is_first
    end

    ##
    # @private
    #
    def delete_ref!(ref)
      ref_data = @data["refs"].delete(ref)
      @modified = true if ref_data
      ref_data
    end

    ##
    # @private
    #
    def access_source!(sha, path)
      @data["accessed"] = @timestamp
      source_info = @data["sources"][sha] ||= {}
      path_info = source_info[path] ||= {}
      is_first = !path_info.key?("accessed")
      path_info["accessed"] = @timestamp
      @modified = true
      is_first
    end

    ##
    # @private
    #
    def delete_source!(sha, path)
      sha_data = @data["sources"][sha]
      return nil if sha_data.nil?
      source_data = sha_data.delete(path)
      if source_data
        @modified = true
        @data["sources"].delete(sha) if sha_data.empty?
      end
      source_data
    end
  end
end
