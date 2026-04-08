# Manifold Self-Hosted Deployment

This repository is a deployment template for running Manifold on your own server using [Kamal 2](https://kamal-deploy.org/). 
Kamal is a deployment tool that orchestrates Docker containers on remote servers via SSH, providing zero-downtime 
deploys, rolling restarts, and accessory service management without requiring Kubernetes or other complex 
infrastructure. Clone this repository to generate customizable Kamal deploy configuration. It contains:

- A **git submodule** pointing to the Manifold source code (pinned to a specific commit)
- Scripts for generating **Kamal configuration** that builds Docker images from the submodule and deploys them to a single VM
- A **local Docker registry** on the server, so you don't need a Docker Hub or GHCR account

Manifold is a twelve factor application. The source code and service images are immutable — configuration is provided 
via environment variables, and persistent state is limited to two areas: **asset storage** and the **database**. Asset 
storage can be handled by the API container's local filesystem (bind-mounted volume), a self-hosted MinIO container 
(S3-compatible object storage), or an external S3-compatible cloud service (AWS S3, DigitalOcean Spaces, Cloudflare R2, 
etc.). The database can run as a PostgreSQL container managed by Kamal, or you can connect to an external managed 
database service

A **destination** is a single deployment instance (e.g. `production`, `staging`). Each destination runs its application 
containers on a server and can optionally use local or external services for the database and storage. By default, 
everything runs on one machine with no managed services required. Multiple destinations can share a single server — each 
gets its own isolated set of containers, volumes, and data directories.

## Architecture

Kamal deploys containers per destination, all connected over a shared Docker network (`kamal`):

| Container                      | Role                              | Image Source              | Managed as           |
|--------------------------------|-----------------------------------|---------------------------|----------------------|
| `manifold-web-<dest>-<hash>`   | Rails API server (primary)        | `manifold/api`            | Server role (web)    |
| `manifold-worker-<dest>-<hash>`| Background job processor (GoodJob)| `manifold/api`            | Server role (worker) |
| `manifold-<dest>-client`       | Client / SSR frontend             | `manifold/client`         | Accessory            |
| `manifold-<dest>-db`           | PostgreSQL 15 database            | `postgres:15-alpine`      | Optional Accessory   |
| `manifold-<dest>-storage`      | MinIO S3-compatible object store  | `minio/minio`             | Optional Accessory   |

The Rails API and worker are **server roles**, which means they share the same Docker image and are deployed together 
with zero downtime by `kamal deploy`. The client runs as an **accessory** with per-destination container names so 
multiple destinations can coexist on one host. When using a local database, a PostgreSQL container is also deployed as 
an accessory; with an external database, no database container is needed.

While the configuration supports running multiple Manifold instances on a single server (e.g. `production` and `staging` 
sharing one VM), this is generally not advisable for production deployments due to resource contention and blast radius 
concerns.

### Database

By default, the database runs as a **local PostgreSQL 15 container** (`manifold-<dest>-db`) deployed as an accessory.

Manifold uses two databases on the same PostgreSQL cluster:
- **Primary database** (`manifold_production`) — application data
- **Cache database** (`manifold_production_cache`) — Rails cache store

Both the API and worker containers connect to the database over the Docker network.

Alternatively, you can configure an **external managed database** (e.g. AWS RDS, DigitalOcean Managed PostgreSQL, Azure 
Database). When using an external database, no PostgreSQL container is deployed. The configure wizard will prompt for 
connection details and credentials.

### Storage

By default, uploaded files are stored on the **local filesystem** (in a bind-mounted Docker volume). This keeps the 
deployment simple — no S3 or MinIO needed. The client proxies `/system` requests to the API, which serves files via 
`RAILS_SERVE_STATIC_FILES`.

If you prefer S3-compatible object storage, the configure wizard offers two options:
- **MinIO** — a self-hosted S3-compatible server deployed as an additional accessory container (`manifold-<dest>-storage`), with kamal-proxy routing `/<dest>-storage/*` requests directly to it
- **S3** — an external S3-compatible service (AWS S3, DigitalOcean Spaces, Cloudflare R2, etc.) with no additional containers needed

### Request routing

kamal-proxy handles incoming HTTPS traffic and routes requests by path:

- `/api/*` requests go to the **API** container
- All other requests go to the **client** container (SSR frontend)

The client also proxies `/system` (uploaded assets) and `/api/proxy` paths to the API internally.

## Prerequisites

- **Ruby** (3.0 or newer) and **Bundler** installed on your local machine (required for the `bin/deploy` CLI)
  - Install Ruby via [ruby-lang.org](https://www.ruby-lang.org/en/documentation/installation/) or a version manager like [rbenv](https://github.com/rbenv/rbenv) or [asdf](https://asdf-vm.com/)
  - Bundler comes with modern Ruby installations, or install with `gem install bundler`
- **A server** running a supported Linux distribution (Ubuntu 22.04+ recommended) with:
  - At least 4 GB RAM (8 GB recommended)
  - At least 2 vCPUs
  - At least 40 GB SSD storage
  - SSH access as root (or a user with Docker permissions)
  - Ports 80 and 443 open to the internet
- **A domain name** (optional but recommended) with a DNS A record pointing to your server's IP address. Without a domain, the server is accessible via its IP address with SSL disabled.
- **Docker** installed on your local machine (where you run Kamal from)

## Quick Start

### 1. Clone this repository

```bash
git clone --recurse-submodules https://github.com/YOUR_ORG/manifold-deploy-example.git
cd manifold-deploy-example
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init
```

### 2. Install dependencies

Install the required Ruby gems:

```bash
bundle install
```

This installs Kamal 2 and the CLI dependencies needed to run `bin/deploy`.

### 3. Configure your deployment

The configure wizard generates your instance configuration and secrets:

```bash
bin/deploy configure
```

It will prompt you for:

| Setting | Default | Notes |
|---------|---------|-------|
| Destination name | `production` | e.g. `production`, `staging` |
| Server IP address | (required) | Your server's public IPv4 address |
| Domain name | (blank = use IP) | If blank, SSL is disabled |
| Server architecture | `amd64` | `amd64` or `arm64` |
| Database | `local` | `local` (container) or `external` (managed) |
| Storage backend | `local` | `local` (filesystem), `minio` (self-hosted), or `s3` (external) |
| Auto-generate secrets | `y` | Generates random keys and passwords |

This creates two files:
- `config/deploy.<dest>.yml` — destination config (deep-merges on top of `deploy.yml`)
- `.kamal/secrets.<dest>` — secrets file

Both are gitignored, so your instance configuration stays out of version control. You can re-run `bin/deploy configure -d <dest>` at any time to regenerate them (existing secrets are preserved).

### 4. Deploy

All Kamal commands use `-d <destination>` to select your configuration:

```bash
kamal setup -d production
```

This will:
- Install Docker on your server (if not already present)
- Start kamal-proxy (handles HTTPS via Let's Encrypt)
- Start a local Docker registry on the server
- Build the API and client images (the client is built by the `.kamal/hooks/pre-build` hook)
- Deploy all containers
- Automatically create the database, run migrations, seed data, and run upgrade tasks

The first deploy takes a few minutes while the database schema is loaded and initial data is seeded. Subsequent deploys are much faster.

### 5. Create an admin user

```bash
bin/deploy admin -d production
```

You'll be prompted for an email, first name, and last name. A temporary password will be assigned automatically.

### 6. Verify

Visit `https://your-domain.com` and log in with the admin account you just created.

## Routine Deployments

When you want to redeploy after a Manifold update or configuration change:

```bash
kamal deploy -d production
```

This does a zero-downtime deploy of the API and worker (both server roles). The `post-deploy` hook automatically restarts the client accessory so it picks up the latest image.

The API container automatically runs migrations and upgrade tasks on startup, so no separate release command is needed.

## Updating Manifold

To update to a newer version of Manifold:

```bash
# Pull the latest from the main branch
cd manifold
git pull origin main
cd ..

# Commit the submodule pointer update
git add manifold
git commit -m "Update Manifold to $(git -C manifold rev-parse --short HEAD)"

# Deploy the new version
kamal deploy -d production
```

To pin to a specific release tag:

```bash
cd manifold
git fetch --tags
git checkout v9.0.0  # or whatever version
cd ..
git add manifold
git commit -m "Pin Manifold to v9.0.0"
```

## Helper Commands

The `bin/deploy` CLI provides commands for common remote operations. All require `-d <destination>`.

| Command                | Description                                        |
|------------------------|----------------------------------------------------|
| `bin/deploy configure`     | Interactive wizard to generate config and secrets  |
| `bin/deploy admin`     | Create an admin user (prompts for email/name)      |
| `bin/deploy status`    | Show containers, volumes, and disk usage           |
| `bin/deploy logs`      | Tail logs from any container                       |
| `bin/deploy remote`    | Run an arbitrary command on the server via SSH     |
| `bin/deploy import`    | Import a v8 backup tar into a destination (replaces DB and files) |
| `bin/deploy nuke`      | Completely remove a deployment (containers, volumes, data) |

Run `bin/deploy --help` for a list of all commands, or `bin/deploy <command> --help` for usage details.

### Examples

```bash
# Create an admin user
bin/deploy admin -d production

# Check what's running
bin/deploy status -d production

# Tail API logs
bin/deploy logs -d production api

# Tail client logs
bin/deploy logs -d production client

# Tail worker logs
bin/deploy logs -d production worker

# Run a command on the server
bin/deploy remote -d production "docker stats --no-stream"

# Import a v8 backup tar into an existing destination
bin/deploy import -d production ./manifold-backup-YYYY-MM-DD.tar

# Completely remove a deployment and start over
bin/deploy nuke -d production
```

## Configuration Reference

### File layout

```
Gemfile                              # Ruby dependencies (dry-cli, tty-prompt, lipgloss, kamal)
bin/deploy                           # CLI entrypoint — run bin/deploy --help
lib/manifold/                        # CLI library code (commands, config, UI, templates)
config/deploy.yml                    # Base config (tracked) — do not edit
config/deploy.<dest>.yml             # Your instance overrides (generated by bin/deploy configure)
.kamal/secrets.<dest>                # Your secrets (generated by bin/deploy configure)
.kamal/hooks/pre-build               # Builds the client image before each deploy
.kamal/hooks/post-deploy             # Restarts the client accessory after each deploy
```

All Kamal commands require `-d <destination>` to load your instance config:

```bash
kamal <command> -d production
```

### Destination override file

The destination file (`config/deploy.<dest>.yml`) is generated by `bin/deploy configure` and deep-merges on top of `deploy.yml`. It sets:

- **Server IP** — for the primary service and all accessories
- **Domain and URLs** — for the proxy, client env, and API env
- **Container naming** — per-destination names (e.g. `manifold-production-db`) so multiple destinations can share a host
- **Database configuration** — local container or external managed database
- **Storage configuration** — local filesystem, MinIO accessory, or external S3
- **Architecture** — if the server is `arm64`

Everything else (builder config, env var defaults, base accessory definitions, registry settings) is inherited from the base.

### Builder

The `builder` section in the base config tells Kamal how to build the API Docker image:

```yaml
builder:
  arch: amd64
  context: ./manifold/api       # Build context is the API subdirectory
  dockerfile: ./manifold/api/Dockerfile
  target: production            # Multi-stage build target
```

The client image is built separately by the `.kamal/hooks/pre-build` hook using the same pattern (`manifold/client/Dockerfile`, `production` target). The pre-build hook also pushes the client image to the local registry and pre-pulls it on the server so it's available when accessories boot (after the registry tunnel closes).

### Proxy and routing

kamal-proxy terminates TLS (via Let's Encrypt) and routes by path:

- The **API** (server role) handles `/api/*` requests on port 3011, configured via `path_prefixes: ["/api"]` and `strip_path_prefix: false` (the full `/api/...` path is forwarded to Rails)
- The **client** accessory handles all other requests on port 3010

With **local storage**, uploaded assets are served by Rails (via `RAILS_SERVE_STATIC_FILES`) and proxied through the client's `/system` route.

With **MinIO storage**, an additional route sends `/manifold-<dest>-storage/*` requests directly to MinIO on port 9000.

### Environment variables — Client

| Variable                       | Value                              | Notes                                      |
|--------------------------------|------------------------------------|--------------------------------------------|
| `NODE_ENV`                     | `production`                       | Fixed                                      |
| `SSL_ENABLED`                  | `true`                             | kamal-proxy handles TLS                    |
| `DOMAIN`                       | Your domain                        | Overridden in destination file             |
| `CLIENT_SERVER_PORT`           | `3010`                             | Port the SSR server listens on             |
| `CLIENT_URL`                   | `https://your-domain`              | Overridden in destination file             |
| `CLIENT_BROWSER_API_URL`       | `https://your-domain`              | Overridden in destination file             |
| `CLIENT_BROWSER_API_CABLE_URL` | `https://your-domain`              | Overridden in destination file             |
| `CLIENT_SERVER_API_URL`        | `http://manifold-<dest>-api:3011`  | Internal API URL over Docker network       |
| `CLIENT_SERVER_PROXIES`        | `true`                             | Client proxies `/system` and `/api/proxy`  |

### Environment variables — API and Worker

| Variable                  | Value                              | Notes                                      |
|---------------------------|------------------------------------|--------------------------------------------|
| `RAILS_ENV`              | `production`                        | Fixed                                      |
| `RACK_ENV`               | `production`                        | Fixed                                      |
| `API_PORT`               | `3011`                              | Internal port, not exposed to internet     |
| `WORKER_COUNT`           | `2`                                 | Puma worker processes (API only)           |
| `RAILS_MAX_THREADS`      | `20`                                | Threads per Puma worker (API only)         |
| `MALLOC_ARENA_MAX`       | `2`                                 | Reduces Ruby memory fragmentation          |
| `RAILS_DB_HOST`          | `manifold-<dest>-db` or external host | Local container or managed host         |
| `RAILS_DB_USER`          | `manifold` or external user         | For local DB, matches `POSTGRES_USER`      |
| `RAILS_DB_NAME`          | `manifold_production` or external name | Primary database                        |
| `RAILS_CACHE_DB_HOST`    | `manifold-<dest>-db` or external host | Same cluster as primary                  |
| `RAILS_CACHE_DB_NAME`    | `<RAILS_DB_NAME>_cache`             | Separate cache database on same cluster    |
| `PGHOST`                 | `manifold-<dest>-db` or external host | Used by `psql` during schema loading     |
| `PGUSER`                 | `manifold` or external user         | Used by `psql` during schema loading       |
| `GOOD_JOB_PROBE_PORT`    | `7001`                              | Health probe port (worker only)            |

The following are added by the configure wizard when **MinIO** or **S3** storage is selected:

| Variable                                    | Value                                     | Notes                     |
|---------------------------------------------|-------------------------------------------|---------------------------|
| `MANIFOLD_SETTINGS_STORAGE_PRIMARY`         | `s3`                                      | Switches to S3 backend    |
| `MANIFOLD_SETTINGS_STORAGE_PRIMARY_PREFIX`  | `store`                                   | S3 key prefix             |
| `MANIFOLD_SETTINGS_STORAGE_CACHE_PREFIX`    | `cache`                                   | S3 cache prefix           |
| `MANIFOLD_SETTINGS_STORAGE_TUS_PREFIX`      | `cache`                                   | S3 tus prefix             |
| `S3_ENDPOINT`                               | Internal MinIO URL or external S3 URL     | Depends on storage type   |
| `S3_FORCE_PATH_STYLE`                       | `true`                                    | `false` for AWS S3        |
| `S3_REGION`                                 | `us-east-1` or user-supplied              | S3 region                 |
| `UPLOAD_BUCKET`                             | Bucket name                               | MinIO or S3 bucket        |

The following are added **only for MinIO**, since MinIO objects are proxied through kamal-proxy under the client domain at `/<dest>-storage/*` (external S3 serves assets directly from its endpoint, so these are not needed):

| Variable                                    | Value                                     | Notes                     |
|---------------------------------------------|-------------------------------------------|---------------------------|
| `UPLOAD_CDN_HOST`                           | `https://your-domain`                     | Public URL for asset downloads |
| `UPLOAD_USE_ASSET_CDN`                      | `true`                                    | Use CDN host for asset URLs |
| `UPLOAD_MAPPED_HOST`                        | `https://your-domain`                     | Maps asset URLs through proxy |

### Secrets

| Secret                  | Description                                       | Derived from        |
|-------------------------|---------------------------------------------------|---------------------|
| `SECRET_KEY_BASE`       | Rails encryption key                              | —                   |
| `RAILS_SECRET_KEY`      | Manifold secret key (alias)                       | `$SECRET_KEY_BASE`  |

The following are added when **local database** is selected (default):

| Secret                  | Description                                       | Derived from        |
|-------------------------|---------------------------------------------------|---------------------|
| `POSTGRES_PASSWORD`     | PostgreSQL container password                     | —                   |
| `RAILS_DB_PASS`         | API database password                             | `$POSTGRES_PASSWORD` |
| `RAILS_CACHE_DB_PASS`   | Cache database password                           | `$POSTGRES_PASSWORD` |
| `PGPASSWORD`            | Used by `psql` during schema loading              | `$POSTGRES_PASSWORD` |

The following are added when **external database** is selected:

| Secret                  | Description                                       | Derived from        |
|-------------------------|---------------------------------------------------|---------------------|
| `RAILS_DB_PASS`         | Database password (prompted during configure)          | —                   |
| `RAILS_CACHE_DB_PASS`   | Cache database password                           | `$RAILS_DB_PASS`   |
| `PGPASSWORD`            | Used by `psql` during schema loading              | `$RAILS_DB_PASS`   |

The following are added when **MinIO storage** is selected:

| Secret                  | Description                                       | Derived from           |
|-------------------------|---------------------------------------------------|------------------------|
| `MINIO_ROOT_USER`       | MinIO admin username                              | Default: `manifold`    |
| `MINIO_ROOT_PASSWORD`   | MinIO admin password                              | —                      |
| `S3_ACCESS_KEY_ID`      | S3 access key for uploads                         | `$MINIO_ROOT_USER`    |
| `S3_SECRET_ACCESS_KEY`  | S3 secret key for uploads                         | `$MINIO_ROOT_PASSWORD` |

The following are added when **external S3 storage** is selected:

| Secret                  | Description                                       | Derived from           |
|-------------------------|---------------------------------------------------|------------------------|
| `S3_ACCESS_KEY_ID`      | S3 access key (prompted during configure)              | —                      |
| `S3_SECRET_ACCESS_KEY`  | S3 secret key (prompted during configure)              | —                      |

## Useful Commands

All commands require `-d production` (or your destination name).

### Aliases

The base config defines aliases for common operations:

```bash
kamal console -d production          # Rails console on the API container
kamal shell -d production            # Bash shell on the API container
kamal logs-api -d production         # API logs
kamal logs-client -d production      # Client logs
kamal logs-worker -d production      # Worker logs
```

### Other commands

```bash
# Check deployment status
kamal app details -d production
kamal accessory details client -d production

# View database logs (local DB only)
kamal accessory logs db -d production

# Run a one-off Rails command
kamal app exec -d production -r web "bin/rails runner 'puts Manifold::VERSION'"

# Stop everything
kamal app stop -d production

# Remove everything (containers, volumes, and data)
bin/deploy nuke -d production
```

## Data and Backups

Persistent data lives on the server only when the corresponding service runs locally:

| Data             | Location                                              | When it exists        |
|------------------|-------------------------------------------------------|-----------------------|
| Database         | `manifold-<dest>-db/data/`                            | Local DB only         |
| Uploads (local)  | `<dest>-uploads` Docker volume                        | Local storage only    |
| Uploads (MinIO)  | `manifold-<dest>-storage/data/`                       | MinIO only            |
| Uploads (S3)     | External S3 bucket                                    | External S3 only      |

To back up a **local** database (external databases should be backed up via your provider's tooling):

```bash
ssh root@your-server "docker exec manifold-production-db pg_dump -U manifold manifold_production" > backup.sql
```

### Importing a v8 backup

If you are migrating from a legacy (v8 or earlier) Manifold installation, you can import the `.tar` backup produced by the old `manifold:backup` task directly into a configured destination:

```bash
bin/deploy import -d production ./manifold-backup-YYYY-MM-DD.tar
```

The tar archive must contain `dump.sql` and an `uploads/` directory at the root (the standard v8 backup layout). The import command will:

1. Upload the tar to a staging directory on the server and extract it.
2. Stop the web and worker containers (accessories like `db` and `client` keep running).
3. Drop and recreate the primary and cache databases, then load `dump.sql` into the primary database.
4. Replace uploaded files in the destination's storage backend (local volume, MinIO accessory, or external S3) with the contents of `uploads/`.
5. Boot the app. On startup, Rails runs pending migrations and `manifold:upgrade` to bring the schema and data up to date with the current (v9+) codebase.
6. Reindex search.

This **replaces** all database and file data for the destination — you will be asked to type `yes` to confirm before anything destructive runs. Run `bin/deploy configure -d <dest>` first if you have not yet configured the destination.

Only v8 **filesystem** backups are supported as a source. If your v8 instance was already using S3 storage, copy the bucket contents directly to your new bucket instead.

## Multiple Destinations

You can deploy multiple Manifold instances to the same server. Each destination gets its own containers, volumes, and data directories:

```bash
bin/deploy configure                    # Creates config/deploy.production.yml
bin/deploy configure -d staging         # Creates config/deploy.staging.yml

kamal setup -d production
kamal setup -d staging
```

Containers are named with per-destination prefixes (`manifold-production-db`, `manifold-staging-db`, etc.) so they don't conflict. All destinations share the same kamal-proxy instance and Docker network.

## Using External Services

The configure wizard (`bin/deploy configure`) natively supports both external databases and external S3 storage. Select `external` for the database prompt or `s3` for the storage prompt, and the wizard will collect the necessary connection details and credentials.

**External database**: When you select `external`, the wizard prompts for host, port, user, and database name. No PostgreSQL container is deployed. The database password is stored in your secrets file.

**Important**: The deploy does not create external databases. Rails bootstraps a new database by connecting to a `postgres` maintenance database, which is not always present on managed services — for example, DigitalOcean Managed PostgreSQL ships with `defaultdb` instead of `postgres`, and `rails db:create` will fail with `FATAL: database "postgres" does not exist`. Create both the primary database and its matching cache database on your cluster before your first deploy (e.g. via your provider's control panel or a `psql` session):

```sql
CREATE DATABASE manifold_production;
CREATE DATABASE manifold_production_cache;
```

The cache database is expected to be named `<db_name>_cache`.

**External S3 storage** (e.g. DigitalOcean Spaces, AWS S3, Cloudflare R2): When you select `s3`, the wizard prompts for endpoint URL, region, bucket name, and access credentials. No MinIO container is deployed.

You can also switch an existing destination between local and external by re-running `bin/deploy configure -d <dest>` — existing secrets are preserved and new ones are prompted as needed.

## Troubleshooting

**Build fails during `kamal setup`:**
Make sure the `manifold` submodule is checked out: `git submodule update --init`.

**SSL certificate not issued:**
Ensure your domain's DNS A record points to the server IP and ports 80/443 are open. Let's Encrypt needs to reach the server to issue certificates.

**Client can't reach the API (`CLIENT_SERVER_API_URL`):**
All containers must be on the `kamal` Docker network. Verify with:
```bash
ssh root@your-server "docker network inspect kamal"
```

**Database connection refused:**
For a **local database**, the container may not be ready yet. Check its status:
```bash
kamal accessory details db -d production
kamal accessory logs db -d production
```
For an **external database**, verify the host, port, credentials, and that the managed cluster allows connections from your server's IP.

**`/api` requests return 502 or 404:**
The API may not be running or healthy. Verify:
```bash
kamal app details -d production
kamal app logs -d production
```

**Assets return 404:**
With **local storage**, ensure `RAILS_SERVE_STATIC_FILES` is `true` (it is by default) and the uploads volume is mounted. With **MinIO**, check that the storage accessory is running:
```bash
bin/deploy status -d production
```
With **external S3**, verify `S3_ENDPOINT`, `UPLOAD_BUCKET`, and `S3_REGION` in `config/deploy.<dest>.yml` are correct, and that the access keys in `.kamal/secrets.<dest>` have `s3:GetObject` / `s3:PutObject` permissions on the bucket.

**`kamal remove` leaves orphaned containers:**
Kamal's `remove` command can fail partway through, leaving stale containers. Use `bin/deploy nuke` instead, which handles cleanup gracefully:
```bash
bin/deploy nuke -d production
```

## License

This deployment template is provided as-is. Manifold itself is licensed under the [GNU General Public License v3.0](https://github.com/ManifoldScholar/manifold/blob/main/LICENSE.md).
