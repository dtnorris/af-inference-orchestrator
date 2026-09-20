# frozen_string_literal: true

require "optparse"

module LocalModelEvaluation
  module ProductionPoolFulfillOptions
    module_function

    def validate!(opts, remaining_args)
      plan_arg = remaining_args.shift
      raise OptionParser::MissingArgument, "PLAN.json" unless plan_arg
      raise OptionParser::MissingArgument, "--pool" unless opts[:pool]
      raise OptionParser::MissingArgument, "--output" unless opts[:output]
      if opts[:dry_run] && opts[:yes]
        raise OptionParser::InvalidArgument, "--dry-run and --yes are mutually exclusive"
      end
      raise OptionParser::InvalidArgument, "use --dry-run or --yes" unless opts[:dry_run] || opts[:yes]
      unless remaining_args.empty?
        raise OptionParser::InvalidArgument, "unexpected arguments: #{remaining_args.join(' ')}"
      end

      plan_arg
    end
  end
end
