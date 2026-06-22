require "securerandom"
require "fileutils"
require_relative "../settings"

module Manifold
  module Commands
    class Configure < Manifold::Command
      desc "Interactive wizard to generate config and secrets"

      option :regenerate, type: :boolean, default: false,
        desc: "Rewrite config files from saved settings without prompting"

      IPV4_REGEX = /\A(\d{1,3}\.){3}\d{1,3}\z/

      def call(**options)
        print_intro
        initialize_settings(options[:destination])
        if options[:regenerate]
          ensure_regeneratable!
        else
          announce_settings_state
          prompt_server
          prompt_database
          prompt_storage
          resolve_secrets
        end
        write_configs
        print_summary
      end

      private

      attr_reader :settings

      def print_intro
        UI.newline
        UI.header "Manifold Deployment Configuration"
        UI.newline
        UI.info "This wizard generates the configuration files needed to deploy Manifold"
        UI.info "to your server. You can re-run it at any time to regenerate them."
      end

      def initialize_settings(dest_opt)
        UI.newline
        dest = dest_opt || prompt.ask("Destination name:", default: "production", required: true)
        @settings = Settings.load(dest)
      end

      def announce_settings_state
        return unless @settings.persisted? || @settings.stale?
        UI.newline
        if @settings.persisted?
          UI.info "Editing existing config for '#{@settings.dest}'. Press enter to keep current values."
        elsif @settings.stale?
          UI.warn "Warning: No saved settings found in #{Config.deploy_file(@settings.dest)}. Starting fresh."
        end
        UI.newline
      end

      def ensure_regeneratable!
        return if @settings.persisted? && @settings.secrets_loaded?

        UI.newline
        UI.error "Cannot regenerate '#{@settings.dest}': no saved settings found."
        UI.info "  Run 'bin/deploy configure -d #{@settings.dest}' first to create them."
        exit 1
      end

      # -- Prompt methods -----------------------------------------------------

      def prompt_server
        ask_setting :server_ip, "Server IP address:", required: true do |q|
          q.validate(IPV4_REGEX, "Invalid IPv4 address")
        end
        ask_setting    :domain, "Domain name (blank = use IP, no SSL):", default: ""
        select_setting :arch,   "Server architecture:", %w[amd64 arm64], default: "amd64"
      end

      def prompt_database
        select_setting :database, "Database:", %w[local external], default: "local"
        return unless @settings.external_database?

        ask_setting :db_host, "Database host:", required: true
        ask_setting :db_port, "Database port:", default: "5432"
        ask_setting :db_user, "Database user:", default: "manifold"
        ask_setting :db_name, "Database name:", default: "manifold_production"
      end

      def prompt_storage
        select_setting :storage, "Storage backend:", %w[local minio s3], default: "local"
        return unless @settings.s3_storage?

        ask_setting :s3_endpoint, "S3 endpoint URL:", required: true
        ask_setting :s3_region,   "S3 region:", default: "us-east-1"
        ask_setting :s3_bucket,   "S3 bucket name:", required: true
        yes_setting :s3_force_path_style,
          "Use path-style URLs? (yes for most providers, no for AWS S3)",
          default: true
      end

      def resolve_secrets
        # Registry credentials: pulling the published images requires a GitHub
        # username and a read:packages PAT (Kamal logs in even for public
        # images). See the README, "Registry access".
        fill_secret :github_username, "GitHub username (for ghcr.io image pulls)"
        fill_secret :registry_pat,    "GitHub read:packages token (PAT)", mask: true

        fill_secret :secret_key_base,      "SECRET_KEY_BASE",      generator: :hex
        fill_secret :postgres_password,    "POSTGRES_PASSWORD",    generator: :password if @settings.local_database?
        fill_secret :db_password,          "Database password"                          if @settings.external_database?
        fill_secret :minio_root_password,  "MINIO_ROOT_PASSWORD",  generator: :password if @settings.minio_storage?
        fill_secret :s3_access_key_id,     "S3 access key ID"                           if @settings.s3_storage?
        fill_secret :s3_secret_access_key, "S3 secret access key"                       if @settings.s3_storage?
      end

      def fill_secret(field, label, generator: nil, mask: false)
        return unless blank?(@settings.public_send(field))
        value =
          if generator && auto_generate?
            generate(generator)
          elsif mask
            prompt.mask("#{label}:", required: true)
          else
            prompt.ask("#{label}:", required: true)
          end
        @settings.public_send("#{field}=", value)
      end

      def auto_generate?
        return @auto_generate if defined?(@auto_generate)
        @auto_generate = @settings.secrets_loaded? || prompt.yes?("Auto-generate secrets where possible?")
      end

      def generate(strategy)
        case strategy
        when :hex      then SecureRandom.hex(64)
        when :password then SecureRandom.alphanumeric(32)
        end
      end

      # -- Setting prompt helpers ---------------------------------------------
      #
      # Each helper reads the current value from @settings, uses it as the
      # default for the prompt (or falls back to the supplied default: if blank),
      # then writes the chosen value back into @settings.

      def ask_setting(key, message, default: nil, required: false, &block)
        current = @settings.public_send(key)
        current = default if blank?(current)
        result = prompt.ask(message, default: current) do |q|
          q.required(required)
          block&.call(q)
        end
        @settings.public_send("#{key}=", result)
      end

      def select_setting(key, message, choices, default: nil)
        current = @settings.public_send(key)
        current = default if blank?(current)
        result = prompt.select(message, choices, default: current)
        @settings.public_send("#{key}=", result)
      end

      # yes? takes a boolean default, so we use nil? rather than blank?
      # (false is a valid value, not a missing value).
      def yes_setting(key, message, default: nil)
        current = @settings.public_send(key)
        current = default if current.nil?
        result = prompt.yes?(message, default: current)
        @settings.public_send("#{key}=", result)
      end

      # -- Output -------------------------------------------------------------

      def write_configs
        deploy_file  = Config.deploy_file(@settings.dest)
        secrets_file = Config.secrets_file(@settings.dest)

        FileUtils.mkdir_p(File.dirname(deploy_file))
        FileUtils.mkdir_p(File.dirname(secrets_file))

        File.write(deploy_file,  render_template("deploy.yml.erb"))
        File.write(secrets_file, render_template("secrets.erb"))
      end

      def print_summary
        deploy_path  = "config/deploy.#{@settings.dest}.yml"
        secrets_path = ".kamal/secrets.#{@settings.dest}"

        UI.newline
        UI.step "Files generated:"
        UI.info "  #{deploy_path}"
        UI.info "  #{secrets_path}"
        UI.newline

        if @settings.ssl_disabled?
          UI.info "Note: No domain was set. SSL is disabled and the server will be"
          UI.info "accessible via http://#{@settings.server_ip}. You can add a domain later by"
          UI.info "re-running bin/deploy configure -d #{@settings.dest}."
          UI.newline
        end

        if @settings.external_database?
          UI.info "Database: external (#{@settings.db_host}:#{@settings.db_port})"
          UI.info "No database container will be deployed."
          UI.newline
          UI.warn "IMPORTANT: External databases are not created by the deploy."
          UI.warn "Create these on your cluster before running bin/deploy setup:"
          UI.info "  CREATE DATABASE #{@settings.db_name};"
          UI.info "  CREATE DATABASE #{@settings.db_name}_cache;"
        else
          UI.info "Database: local PostgreSQL container"
        end
        UI.newline

        case @settings.storage
        when "local"
          UI.info "Storage: local filesystem (uploads persist in /srv/app/public/system)"
          UI.info "No MinIO or S3 configuration is needed."
        when "minio"
          UI.info "Storage: MinIO (S3-compatible object storage)"
          UI.info "The storage accessory will be deployed alongside the application."
        when "s3"
          UI.info "Storage: external S3 (#{@settings.s3_endpoint})"
          UI.info "No storage container will be deployed."
        end

        UI.newline
        UI.step "Next steps:"
        UI.info "  bin/deploy setup -d #{@settings.dest}"
        UI.newline
      end

      def render_template(template_file)
        template = File.read(File.join(Config.templates_dir, template_file))
        b = binding
        b.local_variable_set(:s, @settings)
        ERB.new(template, trim_mode: "-").result(b)
      end

      def blank?(value)
        value.nil? || value.to_s.empty?
      end
    end
  end
end
