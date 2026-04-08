require "securerandom"
require "shellwords"
require_relative "../settings"

module Manifold
  module Commands
    class Import < Manifold::Command
      desc "Import a v8 backup tar into a destination (replaces DB and files)"

      argument :backup, required: true, desc: "Path to v8 backup tar file"

      # Hardcoded to match the `POSTGRES_DB` value in the local DB accessory
      # template. External-DB destinations use @settings.db_name instead.
      LOCAL_PRIMARY_DB = "manifold_production".freeze

      def call(backup:, **options)
        @backup_path = File.expand_path(backup)
        @host, @ssh_user, @dest = resolve_host!(options[:destination])
        @settings = Settings.load(@dest)
        @secrets  = Config.read_secrets(@dest)
        @stage    = "/tmp/manifold-import-#{@dest}-#{SecureRandom.hex(4)}"

        validate_local!
        confirm!
        ensure_staging_dir
        upload_backup
        extract_backup
        validate_extract!
        stop_app
        restore_database
        restore_files
        start_app
        reindex
        cleanup_staging
        print_summary
      end

      private

      # -- steps --------------------------------------------------------------

      def validate_local!
        unless File.file?(@backup_path)
          abort_with "Backup file not found: #{@backup_path}"
        end

        unless @settings.persisted?
          abort_with "No saved settings for '#{@dest}'. Run 'bin/deploy configure -d #{@dest}' first."
        end

        require_secret!("POSTGRES_PASSWORD")   if @settings.local_database?
        require_secret!("RAILS_DB_PASS")       if @settings.external_database?
        require_secret!("MINIO_ROOT_USER")     if @settings.minio_storage?
        require_secret!("MINIO_ROOT_PASSWORD") if @settings.minio_storage?
        require_secret!("S3_ACCESS_KEY_ID")    if @settings.s3_storage?
        require_secret!("S3_SECRET_ACCESS_KEY") if @settings.s3_storage?
      end

      def confirm!
        UI.newline
        UI.header "Import v8 backup into '#{@dest}'"
        UI.newline
        UI.key_value_list(
          "Backup"   => @backup_path,
          "Server"   => @host,
          "Database" => @settings.database,
          "Storage"  => @settings.storage
        )
        UI.newline
        UI.warn "This will REPLACE the database and uploaded files for '#{@dest}'."
        UI.warn "All existing data for this destination will be lost."
        UI.newline

        result = prompt.ask("Type 'yes' to confirm:") do |q|
          q.validate(/\Ayes\z/, "You must type 'yes' to confirm")
          q.required true
        end
        exit 1 unless result == "yes"
        UI.newline
      end

      def ensure_staging_dir
        UI.step "Creating staging directory on #{@host}..."
        ssh_or_abort! "mkdir -p #{@stage}"
        @staging_created = true
      end

      def upload_backup
        UI.step "Uploading backup to server..."
        unless system("scp", "-C", @backup_path, "#{@ssh_user}@#{@host}:#{@stage}/backup.tar")
          abort_with "Failed to upload backup"
        end
      end

      def extract_backup
        UI.step "Extracting backup..."
        ssh_or_abort! "tar -xf #{@stage}/backup.tar -C #{@stage}"
      end

      def validate_extract!
        UI.step "Validating extracted archive..."
        ok = ssh_run(@host, @ssh_user, "test -f #{@stage}/dump.sql && test -d #{@stage}/uploads")
        abort_with "Extracted archive is missing dump.sql or uploads/ at the tar root" unless ok
      end

      def stop_app
        UI.step "Stopping web and worker..."
        %w[web worker].each do |role|
          name = find_app_container(role)
          ssh_or_abort!("docker stop #{name}") if name
        end
      end

      def restore_database
        UI.step "Restoring database (#{@settings.database})..."
        if @settings.local_database?
          restore_local_database
        else
          restore_external_database
        end
      end

      def restore_files
        UI.step "Restoring uploaded files (#{@settings.storage})..."
        if @settings.local_storage?
          restore_local_files
        else
          restore_s3_files
        end
      end

      def start_app
        UI.step "Starting web and worker..."
        %w[web worker].each do |role|
          name = find_app_container(role)
          abort_with "No #{role} container found for '#{@dest}'" unless name
          ssh_or_abort!("docker start #{name}")
        end
      end

      def find_app_container(role)
        out = ssh_capture(@host, @ssh_user,
          "docker ps -a --latest --format '{{.Names}}' " \
          "--filter label=service=manifold " \
          "--filter label=destination=#{@dest} " \
          "--filter label=role=#{role}")
        name = out.to_s.strip
        name.empty? ? nil : name
      end

      def reindex
        UI.step "Reindexing search..."
        cmd = "bin/rails manifold:search:reindex"
        unless system("kamal", "app", "exec", "-d", @dest, "-r", "web", "--reuse", cmd)
          UI.warn "Reindex failed. You can retry manually:"
          UI.info "  kamal app exec -d #{@dest} -r web --reuse \"#{cmd}\""
        end
      end

      def cleanup_staging
        UI.step "Cleaning up staging directory..."
        ssh_run(@host, @ssh_user, "rm -rf #{@stage}")
      end

      def print_summary
        UI.newline
        UI.step "Import complete."
        UI.info "Rails ran pending migrations and manifold:upgrade on boot, so the schema"
        UI.info "is now up-to-date with the v9 codebase."
        UI.newline
        UI.info "The web container may take a minute to finish booting. If the site"
        UI.info "returns 503, tail the API logs to watch progress:"
        UI.info "  bin/deploy logs api -d #{@dest}"
        UI.newline
      end

      # -- database helpers ---------------------------------------------------

      def restore_local_database
        db_container = "#{@settings.svc}-db"
        primary = LOCAL_PRIMARY_DB
        cache   = "#{primary}_cache"

        ssh_or_abort!(
          "docker exec #{db_container} " \
          "psql -U manifold -d postgres -v ON_ERROR_STOP=1 " \
          "#{recreate_db_args(primary, cache, "manifold")}"
        )

        ssh_or_abort!(
          "docker exec -i #{db_container} " \
          "psql -U manifold -d #{primary} -v ON_ERROR_STOP=1 < #{@stage}/dump.sql"
        )
      end

      def restore_external_database
        host = @settings.db_host
        port = @settings.db_port || "5432"
        user = @settings.db_user
        name = @settings.db_name
        cache = "#{name}_cache"
        pw    = @secrets["RAILS_DB_PASS"]

        docker = "docker run --rm --network kamal -e PGPASSWORD=#{Shellwords.escape(pw)}"
        image  = "postgres:15-alpine"
        conn   = "-h #{host} -p #{port} -U #{user}"

        # Managed Postgres providers (e.g. DigitalOcean) don't expose the
        # `postgres` maintenance DB, so we can't DROP/CREATE the target DBs
        # from outside. Instead, reset the public schema inside each
        # pre-existing database. The user is responsible for creating both
        # databases ahead of time.
        [name, cache].each do |db|
          ssh_or_abort!(
            "#{docker} #{image} psql #{conn} -d #{db} -v ON_ERROR_STOP=1 " \
            "#{reset_schema_args}"
          )
        end

        # The v8 dump references the 'manifold' Postgres role, which doesn't
        # exist on managed providers (e.g. DO's admin user is 'doadmin'). Strip
        # ownership and grant/revoke statements that target it; restored
        # objects end up owned by the connecting user, which is what the Rails
        # app uses anyway.
        ssh_or_abort!(
          "sed -i -E '/^(ALTER .* OWNER TO|GRANT .* TO|REVOKE .* FROM) manifold;$/d' #{@stage}/dump.sql"
        )

        ssh_or_abort!(
          "#{docker} -v #{@stage}/dump.sql:/dump.sql:ro #{image} " \
          "psql #{conn} -d #{name} -v ON_ERROR_STOP=1 -f /dump.sql"
        )
      end

      # Builds psql flag args that drop and recreate a primary and cache
      # database. Each statement is its own -c flag because DROP DATABASE
      # cannot run inside a transaction block, and psql wraps a multi-statement
      # -c in a single transaction.
      def recreate_db_args(primary, cache, owner)
        [
          "DROP DATABASE IF EXISTS #{primary} WITH (FORCE)",
          "DROP DATABASE IF EXISTS #{cache} WITH (FORCE)",
          "CREATE DATABASE #{primary} OWNER #{owner}",
          "CREATE DATABASE #{cache} OWNER #{owner}"
        ].map { |stmt| "-c #{Shellwords.escape(stmt)}" }.join(" ")
      end

      # Builds psql flag args that wipe the public schema in the currently
      # connected database. Used for external/managed Postgres providers
      # where we cannot DROP/CREATE the database itself.
      def reset_schema_args
        [
          "DROP SCHEMA IF EXISTS public CASCADE",
          "CREATE SCHEMA public"
        ].map { |stmt| "-c #{Shellwords.escape(stmt)}" }.join(" ")
      end

      # -- file helpers -------------------------------------------------------

      def restore_local_files
        volume = "#{@dest}-uploads"

        ssh_or_abort! <<~BASH
          docker run --rm \
            -v #{volume}:/dest \
            -v #{@stage}/uploads:/src:ro \
            alpine sh -c 'find /dest -mindepth 1 -delete 2>/dev/null; cp -a /src/. /dest/'
        BASH
      end

      def restore_s3_files
        endpoint, key, secret = s3_connection
        bucket = s3_bucket

        ssh_or_abort! <<~BASH
          docker run --rm --network kamal \
            --entrypoint sh \
            -v #{@stage}/uploads:/src:ro \
            -e MC_AK=#{Shellwords.escape(key)} \
            -e MC_SK=#{Shellwords.escape(secret)} \
            minio/mc:latest -c '
              set -e
              mc alias set dst #{endpoint} "$MC_AK" "$MC_SK"
              mc mirror --overwrite --exclude "cache/**" /src dst/#{bucket}/store/
              if [ -d /src/cache ] && [ "$(ls -A /src/cache 2>/dev/null)" ]; then
                mc mirror --overwrite /src/cache dst/#{bucket}/cache/
              fi
            '
        BASH
      end

      def s3_connection
        if @settings.minio_storage?
          [
            "http://#{@settings.svc}-storage:9000",
            @secrets["MINIO_ROOT_USER"],
            @secrets["MINIO_ROOT_PASSWORD"]
          ]
        else
          [
            @settings.s3_endpoint,
            @secrets["S3_ACCESS_KEY_ID"],
            @secrets["S3_SECRET_ACCESS_KEY"]
          ]
        end
      end

      def s3_bucket
        @settings.minio_storage? ? "#{@settings.svc}-storage" : @settings.s3_bucket
      end

      # -- misc ---------------------------------------------------------------

      def require_secret!(key)
        return unless @secrets[key].to_s.empty?
        abort_with "Missing #{key} in .kamal/secrets.#{@dest}"
      end

      def ssh_or_abort!(cmd)
        abort_with "Remote command failed" unless ssh_run(@host, @ssh_user, cmd)
      end

      def abort_with(message)
        UI.newline
        UI.error message
        UI.info "Staging dir left in place for inspection: #{@ssh_user}@#{@host}:#{@stage}" if @staging_created
        exit 1
      end
    end
  end
end
