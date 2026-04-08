require "securerandom"
require "fileutils"

module Manifold
  module Commands
    class Setup < Manifold::Command
      desc "Interactive wizard to generate config and secrets"

      IPV4_REGEX = /\A(\d{1,3}\.){3}\d{1,3}\z/

      def call(**options)
        dest = options[:destination]

        UI.newline
        UI.header "Manifold Deployment Setup"
        UI.newline

        saved, saved_secrets = dest ? load_saved(dest) : [nil, nil]

        if saved
          UI.info "Editing destination '#{dest}'. Press enter to keep current values."
        else
          UI.info "This wizard generates the configuration files needed to deploy Manifold"
          UI.info "to your server. You can re-run it at any time to regenerate them."
        end
        UI.newline

        # -- Destination --------------------------------------------------------

        unless dest
          dest = prompt.ask("Destination name:", default: "production", required: true)
          saved, saved_secrets = load_saved(dest)
          if saved
            UI.newline
            UI.info "Found existing config for '#{dest}'. Press enter to keep current values."
            UI.newline
          end
        end

        # -- Server settings ----------------------------------------------------

        server_ip = prompt.ask("Server IP address:", default: saved&.dig("server_ip")) do |q|
          q.required true
          q.validate(IPV4_REGEX, "Invalid IPv4 address")
        end

        domain = prompt.ask("Domain name (blank = use IP, no SSL):",
          default: saved&.dig("domain") || "")

        arch = prompt.select("Server architecture:", %w[amd64 arm64],
          default: saved&.dig("arch") || "amd64")

        storage = prompt.select("Storage backend:", %w[local minio],
          default: saved&.dig("storage") || "local")

        # -- Secrets ------------------------------------------------------------

        if saved_secrets && !saved_secrets.empty?
          secret_key_base     = saved_secrets["SECRET_KEY_BASE"] || ""
          postgres_password   = saved_secrets["POSTGRES_PASSWORD"] || ""
          minio_root_password = saved_secrets["MINIO_ROOT_PASSWORD"] || ""

          if storage == "minio" && minio_root_password.empty?
            minio_root_password = generate_password
            UI.newline
            UI.info "Generated MINIO_ROOT_PASSWORD for new MinIO storage."
          end
        else
          auto_secrets = prompt.yes?("Auto-generate secrets?")

          if auto_secrets
            secret_key_base     = generate_hex(64)
            postgres_password   = generate_password
            minio_root_password = storage == "minio" ? generate_password : ""
          else
            UI.newline
            secret_key_base     = prompt.ask("SECRET_KEY_BASE:", required: true)
            postgres_password   = prompt.ask("POSTGRES_PASSWORD:", required: true)
            minio_root_password = storage == "minio" ? prompt.ask("MINIO_ROOT_PASSWORD:", required: true) : ""
          end
        end

        # -- Render templates ---------------------------------------------------

        write_configs(dest, server_ip, domain, arch, storage,
                      secret_key_base, postgres_password, minio_root_password)

        # -- Summary ------------------------------------------------------------

        deploy_path = "config/deploy.#{dest}.yml"
        secrets_path = ".kamal/secrets.#{dest}"

        UI.newline
        UI.step "Files generated:"
        UI.info "  #{deploy_path}"
        UI.info "  #{secrets_path}"
        UI.newline

        if domain.nil? || domain.empty?
          UI.info "Note: No domain was set. SSL is disabled and the server will be"
          UI.info "accessible via http://#{server_ip}. You can add a domain later by"
          UI.info "re-running bin/deploy setup -d #{dest}."
          UI.newline
        end

        if storage == "local"
          UI.info "Storage: local filesystem (uploads persist in /srv/app/public/system)"
          UI.info "No MinIO or S3 configuration is needed."
        elsif storage == "minio"
          UI.info "Storage: MinIO (S3-compatible object storage)"
          UI.info "The storage accessory will be deployed alongside the application."
        end

        UI.newline
        UI.step "Next steps:"
        UI.info "  kamal setup -d #{dest}"
        UI.newline
      end

      private

      def load_saved(dest)
        saved = nil
        saved_secrets = nil

        if File.exist?(Config.deploy_file(dest))
          saved = Config.read_saved_settings(dest)
          unless saved
            UI.warn "Warning: No saved settings found in #{Config.deploy_file(dest)}. Starting fresh."
          end
        end

        saved_secrets = Config.read_secrets(dest)

        [saved, saved_secrets]
      end

      def write_configs(dest, server_ip, domain, arch, storage,
                        secret_key_base, postgres_password, minio_root_password)
        deploy_file = Config.deploy_file(dest)
        secrets_file = Config.secrets_file(dest)

        deploy_content = render_template("deploy.yml.erb", binding)
        secrets_content = render_template("secrets.erb", binding)

        FileUtils.mkdir_p(File.dirname(deploy_file))
        FileUtils.mkdir_p(File.dirname(secrets_file))

        File.write(deploy_file, deploy_content)
        File.write(secrets_file, secrets_content)
      end

      def render_template(template_file, binding_obj)
        template = File.read(File.join(Config.templates_dir, template_file))
        ERB.new(template, trim_mode: "-").result(binding_obj)
      end

      def generate_hex(bytes = 64)
        SecureRandom.hex(bytes)
      end

      def generate_password(length = 32)
        SecureRandom.alphanumeric(length)
      end
    end
  end
end
