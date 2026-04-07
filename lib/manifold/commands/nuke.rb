module Manifold
  module Commands
    class Nuke < Manifold::Command
      desc "Completely remove a deployment (containers, volumes, data)"

      def call(**options)
        host, ssh_user, dest = resolve_host!(options[:destination])

        accessories = Config.merged_accessories(dest).keys
        prefix = "manifold-#{dest}"
        containers = accessories.map { |a| "#{prefix}-#{a}" }

        UI.newline
        UI.warn "This will completely remove the Manifold deployment '#{dest}' from #{host}."
        UI.warn "All containers, volumes, and data directories for this destination will be deleted."
        UI.warn "Data that has not been backed up will be lost."
        UI.newline

        confirm = prompt.ask("Type 'yes' to confirm:") do |q|
          q.validate(/\Ayes\z/, "You must type 'yes' to confirm")
          q.required true
        end

        UI.newline

        # Step 1: Try the clean kamal path (accessories first, then app)
        UI.step "Removing accessories via kamal..."
        all_ok = true
        accessories.each do |name|
          UI.info "  Removing #{name}..."
          unless system("kamal", "accessory", "remove", name, "-d", dest, "--confirmed")
            all_ok = false
          end
        end

        UI.step "Removing app via kamal..."
        unless system("kamal", "app", "remove", "-d", dest)
          all_ok = false
        end

        # Step 2: If anything failed, clean up remaining containers directly
        unless all_ok
          UI.newline
          UI.step "Kamal cleanup incomplete, removing remaining containers directly..."
          system("ssh", "#{ssh_user}@#{host}",
            "docker rm -f #{containers.join(' ')} 2>/dev/null; " \
            "docker container prune -f --filter label=service=manifold --filter label=destination=#{dest} 2>/dev/null; " \
            "true"
          )
        end

        # Step 3: Clean up volumes and data directories
        UI.newline
        UI.step "Cleaning up volumes and data directories..."
        system("ssh", "#{ssh_user}@#{host}", <<~BASH)
          docker volume rm #{dest}-uploads 2>/dev/null
          rm -rf #{prefix}-* 2>/dev/null
          true
        BASH

        # Step 4: Verify
        UI.newline
        UI.step "Verifying cleanup..."
        remaining = ssh_capture(host, ssh_user,
          "docker ps -a --format '{{.Names}}' | grep -E '#{prefix}'"
        ).strip

        if remaining.empty?
          UI.step "Destination '#{dest}' removed."
          UI.newline
          UI.info "To redeploy: kamal setup -d #{dest}"
        else
          UI.warn "Some containers remain:"
          puts remaining
          UI.newline
          UI.info "Remove manually: ssh #{ssh_user}@#{host} \"docker rm -f #{remaining.split.join(' ')}\""
        end
      end
    end
  end
end
