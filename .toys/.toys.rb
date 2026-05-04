# frozen_string_literal: true

expand :clean do |t|
  t.paths = :gitignore
  t.preserve = [".claude/plans", ".claude/settings.local.json"]
end

expand :minitest, libs: ["lib", "test"], bundler: true

tool "test" do
  flag :integration_tests, "--integration-tests", "--integration", desc: "Enable integration tests"

  to_run :run_with_integration

  def run_with_integration
    ::ENV["TEST_INTEGRATION"] = "true" if integration_tests
    run
  end
end

expand :rubocop, bundler: true

expand :yardoc do |t|
  t.generate_output_flag = true
  t.fail_on_warning = true
  t.fail_on_undocumented_objects = true
  t.bundler = true
end

expand :gem_build

expand :gem_build, name: "install", install_gem: true
