require "dry/cli"
require_relative "command"
require_relative "commands/setup"
require_relative "commands/status"
require_relative "commands/logs"
require_relative "commands/admin"
require_relative "commands/nuke"
require_relative "commands/remote"

module Manifold
  module CLI
    extend Dry::CLI::Registry

    register "setup",  Commands::Setup
    register "status", Commands::Status
    register "logs",   Commands::Logs
    register "admin",  Commands::Admin
    register "nuke",   Commands::Nuke
    register "remote", Commands::Remote
  end
end
