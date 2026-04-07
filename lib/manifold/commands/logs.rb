module Manifold
  module Commands
    class Logs < Manifold::Command
      desc "Tail logs from a container (api, worker, client, db, storage, proxy)"

      argument :container, required: true, desc: "Container: api, worker, client, db, storage, proxy"
      argument :flags, type: :array, required: false, desc: "Docker log flags (e.g. --tail 50 --no-follow)"

      def call(container:, flags: [], **options)
        host, ssh_user, dest = resolve_host!(options[:destination])
        prefix = "manifold-#{dest}"

        # Default to --tail 100 -f if no flags given
        log_flags = flags.empty? ? "--tail 100 -f" : flags.join(" ")

        resolve = case container
        when "api", "web"
          "docker ps --filter label=service=manifold --filter label=destination=#{dest} --filter label=role=web --format '{{.Names}}' | head -1"
        when "worker"
          "docker ps --filter label=service=manifold --filter label=destination=#{dest} --filter label=role=worker --format '{{.Names}}' | head -1"
        when "client"  then "echo #{prefix}-client"
        when "db"      then "echo #{prefix}-db"
        when "storage" then "echo #{prefix}-storage"
        when "proxy"   then "echo kamal-proxy"
        else "echo #{container}"
        end

        ssh_exec! host, ssh_user, <<~BASH
          CONTAINER_NAME=$(#{resolve})
          if [ -z "$CONTAINER_NAME" ]; then
            echo "No matching container found" >&2
            exit 1
          fi
          docker logs $CONTAINER_NAME #{log_flags}
        BASH
      end
    end
  end
end
