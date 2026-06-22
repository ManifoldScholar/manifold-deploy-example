module Manifold
  module Commands
    # Wrappers around `kamal deploy` / `kamal setup` for the default
    # pull-from-registry workflow. They bury two things Kamal can ONLY take from
    # the CLI (never from config): --skip-push (don't build, just pull the
    # published image) and the version/tag to deploy (default: latest).
    module KamalRun
      DEFAULT_VERSION = "latest".freeze

      def run_kamal!(kamal_command, options)
        dest = options[:destination]
        unless dest
          UI.error "Missing required option: -d <destination>"
          exit 1
        end

        version = options[:version] || ENV["VERSION"] || DEFAULT_VERSION
        exec("kamal", kamal_command, "--skip-push", "--version", version, "-d", dest)
      end
    end

    class Up < Manifold::Command
      include KamalRun

      desc "Deploy the published images to a destination (rolling, no build)"
      option :version, desc: "Image tag to deploy (default: latest)"

      def call(**options)
        run_kamal!("deploy", options)
      end
    end

    class Setup < Manifold::Command
      include KamalRun

      desc "First-time setup: bootstrap the server, then deploy published images"
      option :version, desc: "Image tag to deploy (default: latest)"

      def call(**options)
        run_kamal!("setup", options)
      end
    end
  end
end
