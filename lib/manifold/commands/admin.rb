module Manifold
  module Commands
    class Admin < Manifold::Command
      desc "Create an admin user on the remote Manifold instance"

      def call(**options)
        _, _, dest = resolve_host!(options[:destination])

        email      = prompt.ask("Email:", required: true)
        first_name = prompt.ask("First name:", required: true)
        last_name  = prompt.ask("Last name:", required: true)

        cmd = "bin/rails 'manifold:user:create:admin[#{email},#{first_name},#{last_name}]'"

        exec("kamal", "app", "exec", "-i", "-d", dest, "-r", "web", "--reuse", cmd)
      end
    end
  end
end
