require "yaml"
require "erb"

module Manifold
  module Config
    module_function

    def root
      File.expand_path("../..", __dir__)
    end

    def parse(path)
      YAML.safe_load(ERB.new(File.read(path)).result, aliases: true)
    end

    def deploy_file(dest)
      File.join(root, "config/deploy.#{dest}.yml")
    end

    def secrets_file(dest)
      File.join(root, ".kamal/secrets.#{dest}")
    end

    def templates_dir
      File.join(__dir__, "templates")
    end

    def resolve_host(dest)
      dest_file = deploy_file(dest)
      unless File.exist?(dest_file)
        raise "#{dest_file} not found"
      end

      base = parse(File.join(root, "config/deploy.yml"))
      dest_config = parse(dest_file)

      hosts = dest_config.dig("servers", "web", "hosts") || base.dig("servers", "web", "hosts")
      ssh_user = base.dig("ssh", "user") || "root"

      [hosts.first, ssh_user, dest]
    end

    def merged_accessories(dest)
      base = parse(File.join(root, "config/deploy.yml"))
      dest_config = parse(deploy_file(dest))
      (base["accessories"] || {}).merge(dest_config["accessories"] || {})
    end

    # Parse the "# bin/deploy setup: key=val" comment from a deploy config file.
    # Also supports legacy "# bin/setup: key=val" format.
    def read_saved_settings(dest)
      File.foreach(deploy_file(dest)) do |line|
        if line =~ /^# bin\/(?:deploy setup|setup): (.+)$/
          pairs = $1.strip.split(/\s+/)
          return pairs.each_with_object({}) do |pair, h|
            k, v = pair.split("=", 2)
            h[k] = v
          end
        end
      end
      nil
    end

    # Parse secret values from a secrets file. Returns only raw values (not $VAR references).
    def read_secrets(dest)
      file = secrets_file(dest)
      return {} unless File.exist?(file)

      secrets = {}
      File.foreach(file) do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")
        if line =~ /\A([A-Z_]+)=(.+)\z/
          key, val = $1, $2
          secrets[key] = val unless val.start_with?("$")
        end
      end
      secrets
    end
  end
end
