TTY = "/dev/tty"
REGISTRY_PORT = 5555

def server
  @server ||= ENV.fetch("KAMAL_HOSTS").split(",").first
end

def tty(message)
  File.write(TTY, "#{message}\n")
end

def run(*cmd)
  system(*cmd, out: TTY, err: TTY, exception: true)
end

def run_quiet(*cmd)
  system(*cmd, out: File::NULL, err: File::NULL)
end

def ssh(*cmd)
  system("ssh", "root@#{server}", *cmd, out: TTY, err: TTY, exception: true)
end

def ssh_capture(*cmd)
  IO.popen(["ssh", "root@#{server}", *cmd], err: File::NULL, &:read).strip
end

def image_exists_on_server?(image_ref)
  run_quiet("ssh", "root@#{server}", "docker image inspect #{image_ref}")
end
