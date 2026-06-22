# Manifold Self-Hosted Deployment

This repository is a deployment template for running Manifold on your own server using [Kamal 2](https://kamal-deploy.org/). 
Kamal is a deployment tool that orchestrates Docker containers on remote servers via SSH, providing zero-downtime 
deploys, rolling restarts, and accessory service management without requiring Kubernetes or other complex 
infrastructure. Clone this repository to generate customizable Kamal deploy configuration. It contains:

- Scripts for generating **Kamal configuration** that deploys Manifold's pre-built, **public images** from the GitHub Container Registry (`ghcr.io`) to a single VM — no local build required
- A **git submodule** pointing to the Manifold source code, used only if you choose to build and deploy your own images (see [Deploy from source](#deploy-from-source))

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

| Container                      | Role                              | Image Source                              | Managed as           |
|--------------------------------|-----------------------------------|-------------------------------------------|----------------------|
| `manifold-api-web-<dest>-<hash>`   | Rails API server (primary)    | `ghcr.io/manifoldscholar/manifold-api`    | Server role (web)    |
| `manifold-api-worker-<dest>-<hash>`| Background job processor (GoodJob)| `ghcr.io/manifoldscholar/manifold-api` | Server role (worker) |
| `manifold-<dest>-client`       | Client / SSR frontend             | `ghcr.io/manifoldscholar/manifold-client` | Accessory            |
| `manifold-<dest>-db`           | PostgreSQL 15 database            | `postgres:15-alpine`                      | Optional Accessory   |
| `manifold-<dest>-storage`      | MinIO S3-compatible object store  | `minio/minio`                             | Optional Accessory   |

The Rails API and worker are **server roles**, which means they share the same Docker image and are deployed together 
with zero-downtime rolling restarts. The client runs as an **accessory** with per-destination container names so 
multiple destinations can coexist on one host. When using a local database, a PostgreSQL container is also deployed as 
an accessory; with an external database, no database container is needed.

All three Manifold images (`manifold-api` for both web and worker, `manifold-client`) are **pulled pre-built from 
`ghcr.io`** — deploys do not build anything locally. The published images are public, but Kamal still authenticates to 
the registry, so a GitHub personal access token is required (see [Registry access](#registry-access)).

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
  - SSH access as `root`, **or** a non-root user set up for Docker (see [Deploying as a non-root user](#deploying-as-a-non-root-user))
  - Ports 80 and 443 open to the internet
- **A domain name** (optional but recommended) with a DNS A record pointing to your server's IP address. Without a domain, the server is accessible via its IP address with SSL disabled.
- **A GitHub account** and a `read:packages` personal access token, used to pull the published images (see [Registry access](#registry-access)).

> The default workflow pulls pre-built images, so you do **not** need Docker or the Manifold source on your local machine. Both are only needed if you [deploy from source](#deploy-from-source).

## Registry access

Manifold's images are published **publicly** to the GitHub Container Registry, but Kamal logs in to the registry before pulling — it does this even for public images. You therefore need a GitHub username and a personal access token (PAT) with the **`read:packages`** scope.

Create a token one of two ways:

- **GitHub web UI** (recommended, durable): create a token at [github.com/settings/tokens](https://github.com/settings/tokens) — either a classic PAT with the `read:packages` scope, or a fine-grained token with **Packages: read-only**. See GitHub's docs: [Managing your personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens).
- **GitHub CLI** (quick): reuse the token `gh` already holds.
  ```bash
  gh auth refresh -h github.com -s read:packages
  gh auth token            # use as the token
  gh api user --jq .login  # your username
  ```
  This is your `gh` session token; it rotates/revokes with your `gh` login, so prefer a dedicated PAT for long-lived deployments.

`bin/deploy configure` prompts for your GitHub username and token and stores them in the (gitignored) secrets file as `KAMAL_REGISTRY_USERNAME` / `KAMAL_REGISTRY_PASSWORD`. Kamal logs in with them on each server before pulling.

## Quick Start

### 1. Clone this repository

```bash
git clone https://github.com/ManifoldScholar/manifold-deploy-example.git
cd manifold-deploy-example
```

The `manifold` submodule is only needed if you [deploy from source](#deploy-from-source); the default pull-based workflow does not use it, so you can skip `--recurse-submodules`.

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
| GitHub username | (required) | For pulling images from `ghcr.io` — see [Registry access](#registry-access) |
| GitHub `read:packages` token | (required) | Input is hidden; stored as `KAMAL_REGISTRY_PASSWORD` |
| Auto-generate secrets | `y` | Generates random keys and passwords |

This creates two files:
- `config/deploy.<dest>.yml` — destination config (deep-merges on top of `deploy.yml`)
- `.kamal/secrets.<dest>` — secrets file

Both are gitignored, so your instance configuration stays out of version control. You can re-run `bin/deploy configure -d <dest>` at any time to regenerate them (existing secrets are preserved).

### 4. Deploy

First-time setup bootstraps the server and deploys (all commands use `-d <destination>`):

```bash
bin/deploy setup -d production
```

This will:
- Install Docker on your server (if not already present)
- Start kamal-proxy (handles HTTPS via Let's Encrypt)
- Log in to `ghcr.io` and pull the published API and client images
- Deploy all containers
- Automatically create the database, run migrations, seed data, and run upgrade tasks

`bin/deploy setup` and `bin/deploy up` wrap `kamal setup` / `kamal deploy` with `--skip-push` (pull instead of build) and `--version latest`. To pin a specific published tag, pass `--version <tag>`.

The first deploy takes a few minutes while the database schema is loaded and initial data is seeded. Subsequent deploys are much faster.

### 5. Create an admin user

```bash
bin/deploy admin -d production
```

You'll be prompted for an email, first name, and last name. A temporary password will be assigned automatically.

### 6. Verify

Visit `https://your-domain.com` and log in with the admin account you just created.

## Deploying as a non-root user

By default this template connects as `root` (`ssh.user: root` in
`config/deploy.yml`). To deploy as a regular user instead, set the SSH user in
`config/deploy.yml`:

```yaml
ssh:
  user: deploy
```

> Set this in `config/deploy.yml`, not in a destination file. The destination
> file (`config/deploy.<dest>.yml`) is regenerated every time you run
> `bin/deploy configure`, which would discard an `ssh:` block added there.

For this to work, on the server:

- **Docker must already be installed.** When Docker exists, Kamal runs every
  command directly as your SSH user and never needs `sudo`. (If you let Kamal
  install Docker during `kamal setup`, the user instead needs passwordless
  `sudo` — provisioning that is outside the scope of this guide.)
- **The user must be in the `docker` group** so it can run Docker without
  `sudo`. Verify with `docker ps` over an SSH session as that user.

> **Security note:** the `docker` group is root-equivalent — any member can
> start a container that mounts the host filesystem as root. Using a non-root
> SSH user keeps you from operating as root directly, but it is not a
> meaningful privilege reduction on its own. Treat docker-group access as you
> would root.

## Routine Deployments

To redeploy after a Manifold release or a config change:

```bash
bin/deploy up -d production
```

This pulls the latest published images and does a zero-downtime rolling deploy of the API and worker. The `post-deploy` hook reboots the client accessory so it picks up the latest client image.

The API container automatically runs migrations and upgrade tasks on startup, so no separate release command is needed.

## Updating Manifold

By default each deploy pulls the `latest` images, so updating is just a redeploy:

```bash
bin/deploy up -d production
```

The published tags are:

- **`latest`** — the most recent stable numbered release (the default)
- **`preview`** — a preview of the next stable release
- **`edge`** — the `main` branch; may be unstable

To deploy a specific tag instead of `latest`, pass `--version`:

```bash
bin/deploy up -d production --version preview
```

Available tags are listed on the [Manifold packages](https://github.com/orgs/ManifoldScholar/packages) page.

## Helper Commands

The `bin/deploy` CLI provides commands for common remote operations. All require `-d <destination>`.

| Command                | Description                                        |
|------------------------|----------------------------------------------------|
| `bin/deploy configure`     | Interactive wizard to generate config and secrets  |
| `bin/deploy setup`     | First-time setup: bootstrap the server, then deploy |
| `bin/deploy up`        | Deploy the published images (rolling, no build); `--version <tag>` to pin |
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
.kamal/hooks/post-deploy             # Reboots the client accessory after each deploy
.kamal/hooks/pre-build.sample        # Dormant; activate only to build from source
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

### Registry and images

The base config sets `service: manifold-api`, `image: manifoldscholar/manifold-api`, and `registry.server: ghcr.io`, so the app image resolves to `ghcr.io/manifoldscholar/manifold-api:<tag>`. The client accessory uses `ghcr.io/manifoldscholar/manifold-client`. Deploys pull these published images (the `bin/deploy` wrappers pass `--skip-push`); nothing is built.

`service` must match the `LABEL service` baked into the published API image (`manifold-api`) — on pull, Kamal verifies the image's `service` label equals the configured `service`, so do not change it.

The `builder` block in the base config is unused by the default pull workflow (Kamal validates that it has an `arch`, but never invokes it). It only matters if you [deploy from source](#deploy-from-source).

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
| `KAMAL_REGISTRY_USERNAME` | GitHub username for `ghcr.io`                   | —                   |
| `KAMAL_REGISTRY_PASSWORD` | GitHub `read:packages` token (PAT)              | —                   |
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
kamal dbconsole -d production        # psql on the database (local-database deployments only)
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
ssh <user>@your-server "docker exec manifold-production-db pg_dump -U manifold manifold_production" > backup.sql
```

### Importing a v8 backup

If you are migrating from a legacy (v8 or earlier) Manifold installation, you can import the `.tar` backup produced by the [documented Manifold backup approach](https://manifoldscholar.github.io/manifold-docusaurus/docs/administering/backup_restore):

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

bin/deploy setup -d production
bin/deploy setup -d staging
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

## Deploy from source

The default workflow pulls Manifold's published images. To run your own build instead — to deploy a patched Manifold, or to avoid `ghcr.io` — build the images from the `manifold` submodule and push them to a registry you control (Docker Hub, GHCR under your own account, a private registry, etc.).

1. **Check out the submodule** at the commit/tag you want:
   ```bash
   git submodule update --init
   cd manifold && git checkout v9.0.0 && cd ..   # optional: pin a version
   ```
2. **Point the config at your registry.** In `config/deploy.yml`, set `registry.server` (plus `username`/`password` if it's private) to your registry, set `image:` to your API image path, and set `accessories.client.image:` to your client image path. The `builder` block is already set up to build the API from `manifold/api`.
3. **Activate the client build hook.** Kamal builds the API image, but the client is an accessory, so build + push it via the hook:
   ```bash
   cp .kamal/hooks/pre-build.sample .kamal/hooks/pre-build
   chmod +x .kamal/hooks/pre-build
   ```
   Edit it (or set `MANIFOLD_CLIENT_IMAGE`) to point at your client image path.
4. **Deploy with plain `kamal`** — not `bin/deploy up`/`setup`, which pass `--skip-push`. Plain `kamal` builds and pushes:
   ```bash
   kamal setup  -d production   # first time
   kamal deploy -d production   # subsequent
   ```

This path requires Docker locally and push access to your registry. Keep `service: manifold-api` — the API image must carry `LABEL service=manifold-api` (the Manifold Dockerfile already sets it) to pass Kamal's image check.

## Troubleshooting

**Image pull or registry login fails during deploy:**
Confirm `KAMAL_REGISTRY_USERNAME` / `KAMAL_REGISTRY_PASSWORD` in `.kamal/secrets.<dest>` are a valid GitHub username and a `read:packages` token (see [Registry access](#registry-access)). An `unauthorized`/`denied` error means the token is missing the scope or has expired. If you are [building from source](#deploy-from-source), make sure the submodule is checked out: `git submodule update --init`.

**SSL certificate not issued:**
Ensure your domain's DNS A record points to the server IP and ports 80/443 are open. Let's Encrypt needs to reach the server to issue certificates.

**Client can't reach the API (`CLIENT_SERVER_API_URL`):**
All containers must be on the `kamal` Docker network. Verify with:
```bash
ssh <user>@your-server "docker network inspect kamal"
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
