# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"
require "socket"
require "yaml"

class ProductionBacklogDispatchAdapterTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  EXPECTED_DIGEST = "a" * 64

  def test_dispatch_executable_verifies_digest_unsets_override_and_preserves_argv
    with_fixture(actual_digest: EXPECTED_DIGEST) do |root|
      _out, err, status = run_dispatch(root)

      assert status.success?, err
      assert_equal "unset\n", File.read(File.join(root, "observed-env"))
      assert_equal(
        ["run", "experiments/a manifest.yml"],
        File.readlines(File.join(root, "observed-argv"), chomp: true)
      )
    end
  end

  def test_dispatch_executable_fails_before_lme_when_local_digest_differs
    with_fixture(actual_digest: "b" * 64) do |root|
      _out, err, status = run_dispatch(root)

      refute status.success?
      assert_includes err, "qualified artifact digest mismatch"
      assert_includes err, "expected #{EXPECTED_DIGEST}, got #{'b' * 64}"
      refute File.exist?(File.join(root, "observed-argv"))
    end
  end

  private

  def run_dispatch(root)
    Open3.capture3(
      {
        "LME_REPO" => root,
        "AF_LLM_MAX_TOKENS" => "99999"
      },
      RbConfig.ruby,
      "--disable-gems",
      File.join(ROOT, "bin", "production-backlog-dispatch"),
      "experiments/a manifest.yml",
      ""
    )
  end

  def with_fixture(actual_digest:)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      2.times do
        socket = server.accept
        request_line = socket.gets.to_s
        while (line = socket.gets)
          break if line == "\r\n"
        end
        body = if request_line.include?("/api/version")
                 JSON.dump("version" => "fixture")
               else
                 JSON.dump(
                   "models" => [{
                     "name" => "qwen3.6:35b-a3b",
                     "digest" => actual_digest
                   }]
                 )
               end
        socket.write(
          "HTTP/1.1 200 OK\r\n" \
          "Content-Type: application/json\r\n" \
          "Content-Length: #{body.bytesize}\r\n" \
          "Connection: close\r\n\r\n" \
          "#{body}"
        )
        socket.close
      end
    end

    Dir.mktmpdir("production-dispatch") do |root|
      FileUtils.mkdir_p(File.join(root, "bin"))
      FileUtils.mkdir_p(File.join(root, "config"))
      FileUtils.mkdir_p(File.join(root, "experiments"))
      script = File.join(root, "bin", "lme")
      File.write(script, <<~'SH')
        #!/bin/sh
        set -eu
        printf '%s\n' "${AF_LLM_MAX_TOKENS-unset}" > observed-env
        printf '%s\n' "$@" > observed-argv
      SH
      FileUtils.chmod(0o755, script)
      File.write(
        File.join(root, "config", "models.yml"),
        YAML.dump(
          "models" => {
            "qwen" => {
              "ollama_model" => "qwen3.6:35b-a3b",
              "qualified_manifest_sha256" => EXPECTED_DIGEST
            }
          }
        )
      )
      File.write(
        File.join(root, "config", "workers.yml"),
        YAML.dump(
          "workers" => {
            "mac" => {
              "base_url" => "http://127.0.0.1:#{port}",
              "hourly_rate_usd" => 0.0
            }
          }
        )
      )
      File.write(
        File.join(root, "experiments", "a manifest.yml"),
        YAML.dump("models" => ["qwen"], "workers" => ["mac"])
      )
      yield root
    end
  ensure
    server&.close
    thread&.join
  end
end
