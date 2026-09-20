# frozen_string_literal: true

require "optparse"

module LocalModelEvaluation
  module RpofCampaignValidation
    module_function

    def validate_options!(opts, remaining_args)
      unless remaining_args.empty?
        raise OptionParser::InvalidArgument, "unexpected arguments: #{remaining_args.join(' ')}"
      end
      if opts[:workers] && opts[:all]
        raise OptionParser::InvalidArgument, "use either --workers or --all, not both"
      end
      raise OptionParser::InvalidArgument, "use --workers LIST or --all" unless opts[:workers] || opts[:all]
      %i[context jobs workdir output].each do |key|
        raise OptionParser::MissingArgument, "--#{key.to_s.tr('_', '-')}" if opts[key].nil?
      end
      raise OptionParser::InvalidArgument, "--context must be positive" unless opts[:context].positive?
      raise OptionParser::MissingArgument, "--model" if opts[:models].empty?
      unless opts[:terminal_inactivity_minutes].positive?
        raise OptionParser::InvalidArgument, "--terminal-inactivity-minutes must be positive"
      end
      unless opts[:shutdown_drain_timeout_minutes].positive?
        raise OptionParser::InvalidArgument, "--shutdown-drain-timeout-minutes must be positive"
      end
      unknown_digests = opts[:expected_digests].keys - opts[:models]
      unless unknown_digests.empty?
        raise OptionParser::InvalidArgument,
              "digest supplied for unrequested model(s): #{unknown_digests.join(', ')}"
      end
      expansion_values = [opts[:expansion_plan], opts[:expansion_pool], opts[:initial_fulfillment_seconds]]
      if expansion_values.any? && !expansion_values.all?
        raise OptionParser::InvalidArgument,
              "--expansion-plan, --expansion-pool, and --initial-fulfillment-seconds must be used together"
      end
      if opts[:initial_fulfillment_seconds] && opts[:initial_fulfillment_seconds] <= 0
        raise OptionParser::InvalidArgument, "--initial-fulfillment-seconds must be positive"
      end
      if opts[:expansion_plan] && !opts[:dynamic_worker_admission]
        raise OptionParser::InvalidArgument, "adaptive expansion requires --dynamic-worker-admission"
      end

      true
    end

    def validate_jobs!(jobs_document, source_preflight_queue:)
      jobs = jobs_document.fetch("jobs")
      raise ArgumentError, "jobs must be a non-empty array" unless jobs.is_a?(Array) && !jobs.empty?

      production_manifests = jobs.filter_map do |job|
        argv = job["argv"]
        next unless argv.is_a?(Array) && argv.first.to_s == "bin/lme-production-remote-job"

        unless argv.length == 2 && !argv.fetch(1).to_s.empty?
          raise ArgumentError,
                "production remote campaign job #{job.fetch('job_id', '?')} must use argv " \
                "[\"bin/lme-production-remote-job\", MANIFEST]"
        end
        argv.fetch(1).to_s
      end
      if production_manifests.any? && source_preflight_queue.to_s.empty?
        raise ArgumentError, "production remote campaign jobs require --source-preflight-queue QUEUE"
      end
      if source_preflight_queue && production_manifests.empty?
        raise ArgumentError,
              "--source-preflight-queue requires at least one bin/lme-production-remote-job job"
      end

      [jobs, production_manifests]
    end
  end
end
