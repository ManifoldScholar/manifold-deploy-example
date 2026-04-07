module Manifold
  module Commands
    class Status < Manifold::Command
      desc "Show containers, volumes, and disk usage for a destination"

      def call(**options)
        host, ssh_user, dest = resolve_host!(options[:destination])
        prefix = "manifold-#{dest}"

        ssh_exec! host, ssh_user, <<~BASH
          echo "=== Containers ==="
          docker ps -a --filter name=#{dest} --filter name=kamal-proxy --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'

          echo ""
          echo "=== Volumes ==="
          docker volume ls --filter name=#{dest} --format 'table {{.Name}}\t{{.Driver}}'

          echo ""
          echo "=== Disk (data directories) ==="
          du -sh #{prefix}-* 2>/dev/null || echo "No data directories"

          echo ""
          echo "=== kamal-proxy ==="
          if docker ps --filter name=kamal-proxy --format '{{.Names}}' | grep -q kamal-proxy; then
            docker exec kamal-proxy kamal-proxy status 2>/dev/null || echo "kamal-proxy running (status command not available)"
          else
            echo "kamal-proxy is not running"
          fi
        BASH
      end
    end
  end
end
