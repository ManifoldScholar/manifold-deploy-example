require_relative "config"

module Manifold
  # Mutable, accumulating value object that holds all settings collected by
  # the configure wizard. Knows how to load itself from disk, knows about
  # derived values used by templates, and knows which fields belong in the
  # saved settings comment.
  class Settings
    FIELDS = %i[
      dest
      server_ip domain arch
      database db_host db_port db_user db_name
      storage s3_endpoint s3_region s3_bucket s3_force_path_style
      secret_key_base postgres_password db_password
      minio_root_password s3_access_key_id s3_secret_access_key
    ].freeze

    # Maps secrets-file keys to setting field names. Single source of truth
    # for which raw secret values get loaded back into the wizard.
    SECRET_KEYS = {
      "SECRET_KEY_BASE"      => :secret_key_base,
      "POSTGRES_PASSWORD"    => :postgres_password,
      "RAILS_DB_PASS"        => :db_password,
      "MINIO_ROOT_PASSWORD"  => :minio_root_password,
      "S3_ACCESS_KEY_ID"     => :s3_access_key_id,
      "S3_SECRET_ACCESS_KEY" => :s3_secret_access_key,
    }.freeze

    attr_accessor(*FIELDS)

    # Always returns a Settings instance for the given destination, even if
    # nothing exists on disk yet. Use #persisted? / #secrets_loaded? to ask
    # what was actually loaded.
    def self.load(dest)
      new.tap { |s| s.load_from_disk(dest) }
    end

    def load_from_disk(dest)
      self.dest = dest

      if File.exist?(Config.deploy_file(dest))
        saved = Config.read_saved_settings(dest)
        if saved
          apply_saved_settings(saved)
          @persisted = true
        end
      end

      loaded_secrets = Config.read_secrets(dest)
      if loaded_secrets.any?
        apply_saved_secrets(loaded_secrets)
        @secrets_loaded = true
      end
    end

    def persisted?
      @persisted == true
    end

    def secrets_loaded?
      @secrets_loaded == true
    end

    # True if the deploy file exists but had no settings comment to parse.
    def stale?
      !persisted? && dest && File.exist?(Config.deploy_file(dest))
    end

    # --- predicates ---------------------------------------------------------

    def local_database?    = database == "local"
    def external_database? = database == "external"
    def local_storage?     = storage == "local"
    def minio_storage?     = storage == "minio"
    def s3_storage?        = storage == "s3"
    def s3_compatible?     = minio_storage? || s3_storage?
    def ssl_disabled?      = domain.nil? || domain.to_s.empty?

    # --- derived values used by templates -----------------------------------

    def svc              = "manifold-#{dest}"
    def effective_domain = ssl_disabled? ? server_ip : domain
    def client_url       = ssl_disabled? ? "http://#{server_ip}" : "https://#{domain}"

    # --- serialization ------------------------------------------------------

    # The "# bin/deploy configure: ..." line written into the generated deploy
    # file so that re-running the wizard can recover all prior choices. Only
    # emits the keys that are relevant for the chosen database/storage.
    def to_settings_comment
      keys = %i[server_ip domain arch database]
      keys += %i[db_host db_port db_user db_name] if external_database?
      keys << :storage
      keys += %i[s3_endpoint s3_region s3_bucket s3_force_path_style] if s3_storage?
      keys.map { |k| "#{k}=#{public_send(k)}" }.join(" ")
    end

    private

    def apply_saved_settings(saved)
      saved.each do |k, v|
        field = k.to_sym
        next unless FIELDS.include?(field)
        public_send("#{field}=", coerce(field, v))
      end
    end

    def apply_saved_secrets(secrets)
      SECRET_KEYS.each do |file_key, field|
        public_send("#{field}=", secrets[file_key]) if secrets.key?(file_key)
      end
    end

    def coerce(field, raw)
      case field
      when :s3_force_path_style then raw == "true"
      else raw
      end
    end
  end
end
