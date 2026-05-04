# frozen_string_literal: true

load_gem "toys-ci"

desc "CI target that runs CI jobs in this repo"

flag :bundle_update, "--update", "--bundle-update", desc: "Update instead of install bundles"
flag :integration_tests, "--integration-tests", "--integration", desc: "Enable integration tests"

expand(Toys::CI::Template) do |ci|
  ci.only_flag = true
  ci.fail_fast_flag = true
  ci.before_run do
    ::ENV["TEST_INTEGRATION"] = "true" if integration_tests
  end

  ci.job("Bundle install", flag: :bundle) do
    cmd = bundle_update ? ["bundle", "update", "--all"] : ["bundle", "install"]
    exec(cmd, name: "Bundle").success?
  end
  ci.tool_job("Rubocop", ["rubocop"], flag: :rubocop)
  ci.tool_job("Tests", ["test"], flag: :test)
  ci.tool_job("Yardoc", ["yardoc"], flag: :yard)
  ci.tool_job("Gem build", ["build"], flag: :build)
end
