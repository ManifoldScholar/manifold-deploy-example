# Manifold Self-Hosted Deployment

Deploy [Manifold](https://github.com/ManifoldScholar/manifold) to your own server using [Kamal 2](https://kamal-deploy.org/).

This repository is a deployment template. It contains:

- A **git submodule** pointing to the Manifold source code (pinned to a specific commit)
- A **Kamal configuration** that builds Docker images from the submodule and deploys them to a single VM
- A **local Docker registry** on the server, so you don't need a Docker Hub or GHCR account

Everything runs on one machine: the application, the database, and object storage. No managed services required.

## Architecture

Kamal deploys five containers to a single server, all connected over a shared Docker network (`kamal`):

| Container          | Role                              | Image Source              | Managed as        |
|--------------------|-----------------------------------|---------------------------|--------------------|
| `manifold-web`     | Rails API server (primary)        | `manifold/api`            | Server role (web)  |
| `manifold-worker`  | Background job processor (GoodJob)| `manifold/api`            | Server role (worker)|
| `manifold-client`  | Client / SSR frontend             | `manifold/client`         | Accessory          |
| `manifold-db`      | PostgreSQL 15 database            | `postgres:15-alpine`      | Accessory          |
| `manifold-storage` | S3-compatible object storage      | `minio/minio`             | Accessory          |

The Rails API and worker are **server roles**, which means they share the same Docker image and are deployed together with zero downtime by `kamal deploy`. The client, database, and storage run as **accessories**.

kamal-proxy handles incoming HTTPS traffic and routes requests by path:

- `/api/*` requests go to the **API** container
- `/manifold-storage/*` requests go to **MinIO** (object storage)
- All other requests go to the **client** container (SSR frontend)

The client also proxies `/system` (uploaded assets) and `/api/proxy` paths to the API internally.

```
Internet
  |
  v
kamal-proxy (:80/:443, Let's Encrypt TLS)
  |
  |-- /api/* -----------------> manifold-web (Rails API, :3011)  [server role]
  |                              |---> manifold-db (PostgreSQL, :5432)
  |                              +---> manifold-storage (MinIO, :9000)
  |
  |-- /manifold-storage/* ----> manifold-storage (MinIO, :9000)  [accessory]
  |
  +-- /* ---------------------> manifold-client (SSR frontend, :3010)  [accessory]
                                 +---> manifold-web (internal proxy for /system)

manifold-worker (GoodJob)  [server role]
  |---> manifold-db
  +---> manifold-storage
```

## Prerequisites

- **A server** running a supported Linux distribution (Ubuntu 22.04+ recommended) with:
  - At least 4 GB RAM (8 GB recommended)
  - At least 2 vCPUs
  - At least 40 GB SSD storage
  - SSH access as root (or a user with Docker permissions)
  - Ports 80 and 443 open to the internet
- **A domain name** with a DNS A record pointing to your server's IP address
- **Docker** installed on your local machine (where you run Kamal from)
- **Kamal 2** installed locally: `gem install kamal` (requires Ruby) or use the [Docker image](https://kamal-deploy.org/docs/installation/)

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

### 2. Create your instance configuration

The base `config/deploy.yml` contains all the defaults and should not be edited. Instead, create a **destination file** that overrides only your instance-specific values. Destination files are gitignored, so your instance configuration stays out of version control.

Pick a destination name (e.g. `production`, `staging`, or any name you like):

```bash
cp config/deploy.production.yml.example config/deploy.production.yml
```

Edit `config/deploy.production.yml` and update the two values at the top:

```ruby
server_ip = "203.0.113.1"         # <- Your server's public IP
domain    = "manifold.example.com" # <- Your domain name
```

The rest of the file uses ERB to derive URLs and YAML anchors to propagate these values everywhere they're needed. The destination file deep-merges on top of `deploy.yml`, so all other settings (env vars, builder config, etc.) are inherited automatically.

**Check your server's architecture.** The default builder is configured for `amd64`. If your server uses a different architecture, add a `builder` override to your destination file:

```bash
ssh root@<your-server-ip> uname -m
```

| `uname -m` output | Architecture | Default? |
|--------------------|-------------|----------|
| `x86_64`           | `amd64`     | Yes -- no changes needed |
| `aarch64`          | `arm64`     | Add override below |

If your server is `arm64`, add this to your destination file:

```yaml
builder:
  arch: arm64
```

### 3. Set up secrets

Create a secrets file for your destination:

```bash
cp .kamal/secrets-example .kamal/secrets.production
```

Edit `.kamal/secrets.production` and fill in the three required values:

| Secret               | How to generate                     |
|----------------------|-------------------------------------|
| `SECRET_KEY_BASE`    | `openssl rand -hex 64`              |
| `POSTGRES_PASSWORD`  | Any strong random password          |
| `MINIO_ROOT_PASSWORD`| Any strong random password          |

The remaining secrets (database passwords, S3 credentials, `PGPASSWORD`) are derived automatically via variable substitution in the secrets file.

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
- Automatically create the database, run migrations, seed data, create the storage bucket, and run upgrade tasks

The first deploy takes a few minutes while the database schema is loaded and initial data is seeded. Subsequent deploys are much faster.

### 5. Create an admin user

```bash
bin/remote-admin -d production
```

You'll be prompted for an email, name, and password.

### 6. Verify

Visit `https://your-domain.com` and log in with the admin account you just created.

## Routine Deployments

When you want to redeploy after a Manifold update or configuration change:

```bash
kamal deploy -d production
```

This does a zero-downtime deploy of the API and worker (both server roles). The `post-deploy` hook automatically reboots the client accessory so it picks up the latest image.

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

## Helper Scripts

The `bin/` directory contains helper scripts for common remote operations. All require `-d <destination>`.

| Script              | Description                                        |
|---------------------|----------------------------------------------------|
| `bin/remote-admin`  | Create an admin user (prompts for email/name/password) |
| `bin/remote-status` | Show containers, volumes, images, and disk usage   |
| `bin/remote-logs`   | Tail logs from any container                       |
| `bin/remote`        | Run an arbitrary command on the server via SSH     |
| `bin/remote-nuke`   | Completely remove a deployment (containers, images, data) |

### Examples

```bash
# Create an admin user
bin/remote-admin -d production

# Check what's running
bin/remote-status -d production

# Tail API logs
bin/remote-logs -d production api

# Tail client logs
bin/remote-logs -d production client

# Tail storage logs with custom flags
bin/remote-logs -d production storage --tail 50 --no-follow

# Run a command on the server
bin/remote -d production "docker stats --no-stream"

# Completely remove a deployment and start over
bin/remote-nuke -d production
```

## Configuration Reference

### File layout

```
config/deploy.yml                    # Base config (tracked) -- do not edit
config/deploy.production.yml         # Your instance overrides (untracked)
config/deploy.production.yml.example # Template for the above (tracked)
.kamal/secrets.production            # Your secrets (untracked)
.kamal/secrets-example               # Template for the above (tracked)
.kamal/hooks/pre-build               # Builds the client image before each deploy
.kamal/hooks/post-deploy             # Reboots the client accessory after each deploy
.kamal/hooks/lib/deploy_helpers.rb   # Shared helper methods for hooks
```

All Kamal commands require `-d <destination>` to load your instance config:

```bash
kamal <command> -d production
```

### Destination override file

The destination file (`config/deploy.production.yml`) only needs to contain values that differ from the base. It deep-merges on top of `deploy.yml`. The example override file sets:

- **Server IP** -- for the primary service and all accessories
- **Domain and URLs** -- for the proxy, client env, and API env

Everything else (builder config, env var defaults, accessory definitions, registry settings) is inherited from the base.

### Builder

The `builder` section in the base config tells Kamal how to build the API Docker image:

```yaml
builder:
  arch: amd64
  context: ./manifold/api       # Build context is the API subdirectory
  dockerfile: ./manifold/api/Dockerfile
  target: production            # Multi-stage build target
```

The client image is built separately by the `.kamal/hooks/pre-build` hook using the same pattern (`manifold/client/Dockerfile`, `production` target). The pre-build hook also pushes the client image to the local registry and pre-pulls it on the server.

### Proxy and routing

kamal-proxy terminates TLS (via Let's Encrypt) and routes by path:

- The **API** (server role) handles `/api/*` requests on port 3011, configured via `path_prefixes: ["/api"]` and `strip_path_prefix: false` (the full `/api/...` path is forwarded to Rails)
- **MinIO** (storage accessory) handles `/manifold-storage/*` requests on port 9000, serving uploaded assets directly
- The **client** accessory handles all other requests on port 3010

This matches Manifold's production architecture where `/api` traffic goes directly to Rails without passing through the Node SSR layer, and uploaded assets are served directly from object storage.

### Environment variables -- Client

| Variable                       | Value                              | Notes                                      |
|--------------------------------|------------------------------------|--------------------------------------------|
| `NODE_ENV`                     | `production`                       | Fixed                                      |
| `SSL_ENABLED`                  | `true`                             | kamal-proxy handles TLS                    |
| `DOMAIN`                       | Your domain                        | Overridden in destination file             |
| `CLIENT_SERVER_PORT`           | `3010`                             | Port the SSR server listens on             |
| `CLIENT_URL`                   | `https://your-domain`              | Overridden in destination file             |
| `CLIENT_BROWSER_API_URL`       | `https://your-domain`              | Overridden in destination file             |
| `CLIENT_BROWSER_API_CABLE_URL` | `https://your-domain`              | Overridden in destination file             |
| `CLIENT_SERVER_API_URL`        | `http://manifold-api:3011`         | Internal API URL over Docker network       |
| `CLIENT_SERVER_PROXIES`        | `true`                             | Client proxies `/system` and `/api/proxy`  |

### Environment variables -- API and Worker

| Variable                  | Value                              | Notes                                      |
|---------------------------|------------------------------------|--------------------------------------------|
| `RAILS_ENV`              | `production`                        | Fixed                                      |
| `RACK_ENV`               | `production`                        | Fixed                                      |
| `API_PORT`               | `3011`                              | Internal port, not exposed to internet     |
| `WORKER_COUNT`           | `2`                                 | Puma worker processes (API only)           |
| `RAILS_MAX_THREADS`      | `20`                                | Threads per Puma worker (API only)         |
| `MALLOC_ARENA_MAX`       | `2`                                 | Reduces Ruby memory fragmentation          |
| `RAILS_DB_HOST`          | `manifold-db`                       | Docker network hostname                   |
| `RAILS_DB_USER`          | `manifold`                          | Matches POSTGRES_USER                      |
| `RAILS_DB_NAME`          | `manifold_production`               | Primary database                           |
| `RAILS_CACHE_DB_HOST`    | `manifold-db`                       | Same PostgreSQL instance                   |
| `RAILS_CACHE_DB_NAME`    | `manifold_cache_production`         | Separate cache database                    |
| `S3_ENDPOINT`            | `http://manifold-storage:9000`      | Internal MinIO URL                         |
| `S3_FORCE_PATH_STYLE`    | `true`                              | Required for MinIO                         |
| `S3_REGION`              | `us-east-1`                         | S3 region (MinIO ignores this)             |
| `UPLOAD_BUCKET`          | `manifold-storage`                  | MinIO bucket name                          |
| `UPLOAD_CDN_HOST`        | `https://your-domain`               | Public URL for asset downloads             |
| `PGHOST`                 | `manifold-db`                       | Used by `psql` during schema loading       |
| `PGUSER`                 | `manifold`                          | Used by `psql` during schema loading       |
| `GOOD_JOB_PROBE_PORT`    | `7001`                              | Health probe port (worker only)            |

### Secrets

| Secret                  | Description                                       | Derived from        |
|-------------------------|---------------------------------------------------|---------------------|
| `SECRET_KEY_BASE`       | Rails encryption key                              | --                  |
| `RAILS_SECRET_KEY`      | Manifold secret key (alias)                       | `$SECRET_KEY_BASE`  |
| `POSTGRES_PASSWORD`     | PostgreSQL password                               | --                  |
| `MINIO_ROOT_PASSWORD`   | MinIO admin password                              | --                  |
| `MINIO_ROOT_USER`       | MinIO admin username                              | Default: `manifold` |
| `RAILS_DB_PASS`         | API database password                             | `$POSTGRES_PASSWORD` |
| `RAILS_CACHE_DB_PASS`   | Cache database password                           | `$POSTGRES_PASSWORD` |
| `PGPASSWORD`            | Used by `psql` during schema loading              | `$POSTGRES_PASSWORD` |
| `S3_ACCESS_KEY_ID`      | S3 access key for uploads                         | `$MINIO_ROOT_USER`  |
| `S3_SECRET_ACCESS_KEY`  | S3 secret key for uploads                         | `$MINIO_ROOT_PASSWORD` |

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

# View database or storage logs
kamal accessory logs db -d production           # PostgreSQL logs
kamal accessory logs storage -d production      # MinIO logs

# Run a one-off Rails command
kamal app exec -d production -r web "bin/rails runner 'puts Manifold::VERSION'"

# Restart a specific accessory
kamal accessory reboot client -d production
kamal accessory reboot storage -d production

# Stop everything
kamal app stop -d production

# Remove everything (containers, images, and data)
bin/remote-nuke -d production
```

## Data and Backups

Persistent data is stored in bind-mounted directories on the server:

| Accessory  | Container path               | Contents                  |
|------------|------------------------------|---------------------------|
| `db`       | `/var/lib/postgresql/data`   | PostgreSQL data files     |
| `storage`  | `/data`                      | MinIO object storage      |

To back up the database:

```bash
ssh root@your-server "docker exec manifold-db pg_dump -U manifold manifold_production" > backup.sql
```

## Using External Services

The default configuration runs PostgreSQL and MinIO as Docker containers on the same server. If you prefer managed services (e.g. a managed PostgreSQL database or S3-compatible storage like DigitalOcean Spaces or AWS S3):

1. Remove the `db` and/or `storage` accessory from `config/deploy.yml` (or override them in your destination file)
2. Update the environment variables via your destination file:

**For an external database**, override the `RAILS_DB_*` and `RAILS_CACHE_DB_*` variables to point to your managed database. Alternatively, you can replace all the individual database variables with `DATABASE_URL` and `CACHE_DATABASE_URL` (Rails connection strings).

**For external S3-compatible storage**, override:
```yaml
S3_ENDPOINT: "https://nyc3.digitaloceanspaces.com"  # or your provider's endpoint
S3_REGION: "us-east-1"                                # your bucket's region
S3_FORCE_PATH_STYLE: "true"                           # may need to be "false" for AWS S3
UPLOAD_BUCKET: "your-bucket-name"
```
And set `S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY` in your secrets file to your provider's credentials.

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
The `manifold-db` container may not be ready yet. Check its status:
```bash
kamal accessory details db -d production
kamal accessory logs db -d production
```

**`/api` requests return 502 or 404:**
The API may not be running or healthy. Verify:
```bash
kamal app details -d production
kamal app logs -d production
```

**Assets return 404:**
Check that the storage accessory's proxy host matches your domain and that MinIO is running:
```bash
bin/remote-status -d production
```

**`kamal remove` leaves orphaned containers:**
Kamal's `remove` command can fail partway through, leaving stale containers. Use `bin/remote-nuke` instead, which handles cleanup gracefully:
```bash
bin/remote-nuke -d production
```

## License

This deployment template is provided as-is. Manifold itself is licensed under the [GNU General Public License v3.0](https://github.com/ManifoldScholar/manifold/blob/main/LICENSE.md).
