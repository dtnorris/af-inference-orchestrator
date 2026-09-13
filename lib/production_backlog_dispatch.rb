# frozen_string_literal: true

module ProductionBacklogDispatch
  class SystemCommandAdapter
    def initialize(repo_root:)
      @repo_root = File.expand_path(repo_root)
    end

    def run(environment:, argv:)
      system(environment, *argv, chdir: @repo_root)
    end
  end

  class Runner
    def initialize(command_adapter:, lme_path: "bin/lme")
      @command_adapter = command_adapter
      @lme_path = lme_path
    end

    def dispatch(manifest:, runtime_max_tokens:)
      environment = {
        "AF_LLM_MAX_TOKENS" => runtime_max_tokens.to_s == "8192" ? "8192" : nil
      }
      @command_adapter.run(
        environment:,
        argv: [@lme_path, "run", manifest]
      )
    end
  end
end
