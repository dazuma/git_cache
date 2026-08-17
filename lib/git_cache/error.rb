# frozen_string_literal: true

class GitCache
  ##
  # GitCache encountered a failure
  #
  class Error < ::StandardError
    ##
    # Create a GitCache::Error.
    #
    # @param message [String] The error message
    # @param result [::ExecService::Result,nil] The result of a git
    #     command execution. Omit or pass `nil` if this error was not due to
    #     a git command error.
    #
    def initialize(message, result = nil)
      super(message)
      @exec_result = result
    end

    ##
    # @return [::ExecService::Result] The result of a git command
    #     execution, or `nil` if this error was not due to a git command
    #     error.
    #
    attr_reader :exec_result
  end
end
