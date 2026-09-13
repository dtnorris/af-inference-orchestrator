# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/production_backlog_dispatch"

class ProductionBacklogDispatchTest < Minitest::Test
  class FakeCommandAdapter
    attr_reader :calls

    def initialize(result: true)
      @result = result
      @calls = []
    end

    def run(environment:, argv:)
      @calls << { environment:, argv: }
      @result
    end
  end

  def test_dispatch_sets_only_the_qualified_token_override
    adapter = FakeCommandAdapter.new
    runner = ProductionBacklogDispatch::Runner.new(command_adapter: adapter)

    assert runner.dispatch(manifest: "experiments/core.yml", runtime_max_tokens: "8192")
    assert runner.dispatch(manifest: "experiments/excluded.yml", runtime_max_tokens: nil)

    assert_equal(
      [
        {
          environment: { "AF_LLM_MAX_TOKENS" => "8192" },
          argv: ["bin/lme", "run", "experiments/core.yml"]
        },
        {
          environment: { "AF_LLM_MAX_TOKENS" => nil },
          argv: ["bin/lme", "run", "experiments/excluded.yml"]
        }
      ],
      adapter.calls
    )
  end

  def test_dispatch_propagates_command_failure
    adapter = FakeCommandAdapter.new(result: false)
    runner = ProductionBacklogDispatch::Runner.new(command_adapter: adapter)

    refute runner.dispatch(manifest: "experiments/case.yml", runtime_max_tokens: nil)
  end
end
