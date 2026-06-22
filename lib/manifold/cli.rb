require "dry/cli"
require_relative "command"
require_relative "commands/configure"
require_relative "commands/deploy"
require_relative "commands/status"
require_relative "commands/logs"
require_relative "commands/admin"
require_relative "commands/nuke"
require_relative "commands/remote"
require_relative "commands/import"

module Manifold
  module CLI
    extend Dry::CLI::Registry

    register "configure", Commands::Configure
    register "setup",     Commands::Setup
    register "up",        Commands::Up
    register "status",    Commands::Status
    register "logs",      Commands::Logs
    register "admin",     Commands::Admin
    register "nuke",      Commands::Nuke
    register "remote",    Commands::Remote
    register "import",    Commands::Import
  end
end
