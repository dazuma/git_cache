# frozen_string_literal: true

desc "Initialize the environment for CI systems"

include :exec
include :fileutils

def run
  changed = false
  if exec(["git", "config", "--global", "--get", "user.email"], out: :null).error?
    puts "CI-init: Initializing user.email"
    exec(["git", "config", "--global", "user.email", "hello@example.com"], e: true)
    changed = true
  end
  if exec(["git", "config", "--global", "--get", "user.name"], out: :null).error?
    puts "CI-init: Initializing user.name"
    exec(["git", "config", "--global", "user.name", "Hello Ruby"], e: true)
    changed = true
  end
  puts "CI-init: No changes needed" unless changed
end
