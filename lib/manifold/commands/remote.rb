module Manifold
  module Commands
    class Remote < Manifold::Command
      desc "Run a command on the server via SSH"

      argument :cmd, type: :array, required: true, desc: "Command to run"

      def call(cmd:, **options)
        host, ssh_user, _ = resolve_host!(options[:destination])

        if cmd.empty?
          UI.error "Usage: bin/deploy remote -d <destination> <command>"
          exit 1
        end

        exec("ssh", "#{ssh_user}@#{host}", *cmd)
      end
    end
  end
end
