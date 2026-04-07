require "dry/cli"
require_relative "config"
require_relative "ui"

module Manifold
  class Command < Dry::CLI::Command
    option :destination, aliases: ["-d"], desc: "Deployment destination"

    private

    def resolve_host!(destination)
      unless destination
        UI.error "Missing required option: -d <destination>"
        exit 1
      end

      Config.resolve_host(destination)
    rescue => e
      UI.error e.message
      exit 1
    end

    def ssh_exec!(host, user, cmd)
      exec("ssh", "#{user}@#{host}", cmd)
    end

    def ssh_run(host, user, cmd)
      system("ssh", "#{user}@#{host}", cmd)
    end

    def ssh_capture(host, user, cmd)
      IO.popen(["ssh", "#{user}@#{host}", cmd], &:read)
    end

    def prompt
      @prompt ||= begin
        require "tty-prompt"
        TTY::Prompt.new
      end
    end
  end
end
