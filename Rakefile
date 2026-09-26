# frozen_string_literal: true

require "minitest/test_task"

TEST_RUNTIME_WARNING_SECONDS = 6.0
TEST_RUNTIME_CEILING_SECONDS = 6.5

Minitest::TestTask.create do |t|
  t.test_globs = ["test/**/*_test.rb"]
  t.test_prelude = %(require "simplecov"; SimpleCov.start) if ENV["COVERAGE"]
end

desc "Run the test suite with its wall-clock runtime guard"
task "test:runtime" do
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  sh "bundle", "exec", "rake", "test"
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

  puts format("Whole-suite runtime: %.3f s", elapsed)

  if elapsed >= TEST_RUNTIME_CEILING_SECONDS
    abort format(
      "Test suite runtime %.3f s reached the %.1f s hard ceiling",
      elapsed,
      TEST_RUNTIME_CEILING_SECONDS
    )
  elsif elapsed >= TEST_RUNTIME_WARNING_SECONDS
    warn format(
      "WARNING: test suite runtime %.3f s reached the %.1f s warning threshold",
      elapsed,
      TEST_RUNTIME_WARNING_SECONDS
    )
  end
end

desc "Check structural Minitest test quality"
task "test:lint" do
  sh "bundle", "exec", "rubocop", "--config", ".rubocop.yml", "test"
end

desc "Run tests with line and branch coverage"
task "test:coverage" do
  sh({ "COVERAGE" => "1" }, "bundle", "exec", "rake", "test")
end

desc "Measure current coverage and initialize the committed ratchet baseline"
task "test:coverage:baseline" do
  sh({ "COVERAGE" => "1" }, "bundle", "exec", "rake", "test")
  sh "bundle", "exec", "simplecov", "ratchet", "--init"
end

desc "Run the complete test-suite contract"
task "test:contract" => ["test:runtime", "test:deps", "test:lint", "test:coverage"]

task default: :test
