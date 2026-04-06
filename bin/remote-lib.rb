require "yaml"
require "erb"

def parse_config(path)
  YAML.safe_load(ERB.new(File.read(path)).result, aliases: true)
end

def resolve_host_from_argv
  dest = nil
  remaining = []

  i = 0
  while i < ARGV.length
    if ARGV[i] == "-d"
      dest = ARGV[i + 1]
      i += 2
    else
      remaining << ARGV[i]
      i += 1
    end
  end

  if dest.nil?
    warn "Usage: #{$PROGRAM_NAME} -d <destination> [args...]"
    exit 1
  end

  dest_file = "config/deploy.#{dest}.yml"
  unless File.exist?(dest_file)
    warn "Error: #{dest_file} not found"
    exit 1
  end

  base = parse_config("config/deploy.yml")
  dest_config = parse_config(dest_file)

  hosts = dest_config.dig("servers", "web", "hosts") || base.dig("servers", "web", "hosts")
  ssh_user = base.dig("ssh", "user") || "root"

  [hosts.first, ssh_user, dest, remaining]
end

def ssh_exec(host, ssh_user, command)
  exec("ssh", "#{ssh_user}@#{host}", command)
end
