# How It Works

On a server, every command here runs as root. On your own computer, the same commands run as you, against a [local copy](#a-local-copy-for-testing).

## Shared Services

Every server runs these containers from this repository's `docker-compose.yml`:

| Container | Purpose |
|-----------|---------|
| `shared-caddy` | Terminates HTTPS on ports 80 and 443 for the server's own hostname and every project's domains, obtaining certificates automatically, and shows a [maintenance page](#maintenance-pages) when a project can't answer. `caddy/Caddyfile` imports the configuration the scripts write to `generated/caddy/`. |
| `shared-webhook` | Receives GitHub push webhooks at `/hooks/<project>`. A request signed with that project's secret, for a push to the branch the server deploys, writes the project's trigger file in `generated/triggers/`. It has no Docker access. |
| `shared-mariadb` | The [shared database](#databases), MariaDB 12.3 LTS, holding a database for each project that uses one. It starts the first time such a project is deployed, so a server without one never runs it. |

Caddy and the webhook listener join the `web` Docker network, which each project's web service joins too. The shared database is on no network that projects share; it joins each project's own database network instead. The Compose project is named `shared`, so its volumes are `shared_caddy_data`, `shared_caddy_config`, and `shared_mariadb_data`.

The server's own hostname (`SERVER_HOSTNAME`, such as `stage.wetfish.net`) receives the webhooks for every project at `/hooks/`. Every other path goes to the project whose domains include the hostname, or, if none does, answers `OK` for checking that the server is up. It always sends `X-Robots-Tag: noindex, nofollow` so search engines leave it out.

## Setup

`setup.sh` runs as root on Debian 13 or Ubuntu and is safe to re-run. It:

1. Clones this repository into `/srv/wetfish-server` when run by itself (piped from curl, or saved as a lone file), then continues with the clone's own copy of the script. Run from a clone, it uses that clone wherever it is.
2. Asks for the server's hostname, whether it is a staging or production server, and whether to turn on [Cloudflare-only mode](cloudflare.md), before any long-running step.
3. Installs git, curl, jq, and openssl, then Docker Engine and the Compose plugin from Docker's apt repository, and caps container logs at 100 MB each with Docker's `local` log driver, unless `/etc/docker/daemon.json` already exists.
4. Adds a 1 GiB swap file if the server has less than 2 GiB of memory and no swap.
5. Creates the `deploy` user, which has no password or login shell; the webhook listener runs as this user.
6. Allows ports 80 and 443 in ufw, if ufw is active.
7. Writes `.env`, generating the [shared database](#databases)'s root password the first time, creates `config/` and `generated/`, installs the systemd units that run [deploys](#deploys), applies the [project configuration](#projects), and builds and starts the shared services, including the shared database if it is already running.
8. Turns on Cloudflare-only mode, if chosen.

| Option | Effect |
|--------|--------|
| `--hostname <name>` | Sets the server's hostname |
| `--environment staging\|production` | Sets whether this is a staging or production server |
| `--cloudflare` | Turns on Cloudflare-only mode |
| `--no-cloudflare` | Leaves Cloudflare-only mode off |

Options also work when piping from curl:

```bash
curl -fsSL https://raw.githubusercontent.com/wetfish/server/main/setup.sh | bash -s -- --hostname stage.example.com --environment staging --no-cloudflare
```

Without a terminal to ask on, a missing hostname or environment is an error and Cloudflare-only mode stays off. On a re-run, the settings in `.env` are kept unless options change them, and Cloudflare-only mode, if on, is applied again.

### A Local Copy for Testing

Run as yourself from a clone, `setup.sh` sets up a local copy instead, for trying projects on your own computer before they reach a server. It needs Docker, usable without sudo, jq, and ports 80 and 443 free:

```bash
git clone https://github.com/wetfish/server.git
cd server
./setup.sh
```

It installs nothing and changes nothing outside the clone: it writes `.env`, applies the configuration, and starts the shared services. `https://localhost/` answers `OK`, with a certificate from Caddy's own local authority, which browsers do not trust; use `curl -k`, or accept the warning. The environment is staging, unless `--environment production` is given. Give each project a domain such as `glitch.localhost`, which needs no DNS. Cloudflare-only mode is not available.

## Projects

Add a project with `add-project.sh`, which asks for anything not given as an option:

```bash
./add-project.sh --name glitch --repo https://github.com/wetfish/glitch.git --domain stage-glitch.wetfish.net
```

| Option | Effect |
|--------|--------|
| `--name <name>` | The project's name, which names its webhook URL and containers: lowercase letters, numbers, and `-`, starting with a letter |
| `--repo <url or path>` | The project's Git repository. A local clone's path works too, for deploying commits that are not pushed yet. |
| `--domain <domain>` | A domain the project answers on; repeat for more. Redirects go to the first one, and one of them can be the server's own hostname. |
| `--redirect <domain>` | A domain that permanently redirects to the first domain, such as `www.example.com`; repeat for more |
| `--branch <branch>` | The branch to deploy, instead of `main` on staging or `release` on production |
| `--upstream <service:port>` | The Compose service and port that serve the project, instead of `nginx:80` |

It writes `config/<name>.conf` with a new webhook secret, sets up the env files the project's [setup.conf](#project-setup) asks for, asking for any values that have to be entered by hand, applies the configuration, deploys the project for the first time, and prints the webhook to add in GitHub, under the repository's Settings → Webhooks: the payload URL, content type `application/json`, the secret, and only the push event. If the project cannot be added, for example because another project already uses one of its domains, or the add is interrupted, nothing changes, though its clone in `projects/<name>` is kept for adding it again. If only its first deploy fails, the project stays added: fix the problem and run `./deploy.sh <name>`.

Remove a project with `./remove-project.sh <name>`, which asks to confirm unless given `--yes`. It stops the project's containers; its domains stop being served and its webhook stops working, so delete the webhook in GitHub too. Its env files in `config/<name>/` are deleted. Its clone in `projects/<name>`, its Docker volumes, and its [database](#databases) are kept; it prints how to delete the database.

### Project Setup

A project lists the settings it needs on a server in a `setup.conf` at the top of its repository, so it can be added and deployed without editing anything by hand. Each line names an env file in the repository, a variable in it, and where its value comes from:

```text
# <env file> <variable> <value>
php.env DB_HOST        database host
php.env DB_DATABASE    database name
php.env DB_USERNAME    database user
php.env DB_PASSWORD    database password
php.env SITE_URL       domain
php.env APP_KEY        random base64 32
php.env SMTP_HOST      ask SMTP server
php.env SMTP_PASSWORD  secret SMTP password

# SQL that creates the project's tables in its new database
schema schema.sql
```

| Value | Filled in with |
|-------|----------------|
| `database host`, `port`, `name`, `user`, `password` | The project's database on the [shared database](#databases): `shared-mariadb`, `3306`, its database name, which is also its user, and its password. Any of these gives the project a database, adding a `DATABASE_PASSWORD` to its config file. |
| `domain`, `url` | The project's first domain, such as `glitch.wetfish.net`, or its `https://` URL |
| `random hex <bytes>`, `random base64 <bytes>` | A random secret of 8 to 256 bytes, as hex or base64 |
| `ask <text>` | A value asked for with the text, offering the value in the env file's example as the default |
| `secret <text>` | A value asked for with the text, without showing what is typed. It can be left empty. |

A `schema <file>` line names a SQL file in the repository that creates the project's tables. It runs once, when a deploy first creates the project's [database](#databases), and never again, so changes to it later don't reach an existing database. It also gives the project a database. To start a project's local database the same way, mount the file into the database image's `/docker-entrypoint-initdb.d/` in `docker-compose.override.yml`, which runs it only while the database is empty.

Each env file starts as a copy of the repository's `<file>.example`, such as `php.env.example`, if it has one, so settings that need no server value keep their example values. Env files must not be tracked in the repository, and values cannot contain a single quote. Values that aren't plain letters, numbers, and punctuation such as `.@:/+=-` are written in single quotes, which Compose reads literally.

The files are kept in `config/<name>/`, readable only by their owner, so moving to a new server with a copy of `config/` brings them along. Each deploy copies them into the project's clone, where its Compose file reads them, and never through a symbolic link in the repository or over a tracked file.

Values already in a file are kept, except those filled in from the server's settings, which every deploy writes again, so changing a project's domains or database password and deploying updates them. To change another value, edit the file in `config/<name>/` and deploy again. When a newer `setup.conf` asks for a value that can be generated, the next deploy adds it. One that has to be entered by hand stops the deploy, with the old containers still running, until it is entered:

```bash
./configure-project.sh glitch
./deploy.sh glitch
```

`configure-project.sh` asks only for the values that are missing. Without a terminal, such as when adding a project unattended, values that have to be entered by hand are an error, and the project is not added.

### Configuration Files

`config/` is never committed, so every server keeps its own list of projects. Each `config/<name>.conf` is readable only by its owner, because it holds the webhook secret:

```ini
REPO=https://github.com/wetfish/glitch.git
DOMAINS=stage-glitch.wetfish.net
WEBHOOK_SECRET=3f9c...
```

The other settings are `BRANCH`, `REDIRECTS`, and `UPSTREAM`, matching the options above, and `DATABASE_PASSWORD`, which gives the project a [database](#databases). Domains are separated by spaces.

To change a project, edit its file and run `./apply.sh`. It checks every file first and changes nothing if any has a problem. Then it:

- writes each project's Caddy site to `generated/caddy/sites/<name>.Caddyfile`, and what the server's own hostname serves to `generated/caddy/hostname/`;
- writes each project's webhook, at `https://<SERVER_HOSTNAME>/hooks/<name>`, to `generated/webhook/hooks.json`;
- reloads Caddy, putting the previous files back if Caddy rejects the new ones, and restarts the webhook listener if the webhooks changed;
- on a server, turns on each project's deploys, and turns off those of removed projects;
- prints each project's branch, domains, and webhook URL.

If a webhook secret leaks, give the project a new one and update it in GitHub:

```bash
sed -i "s/^WEBHOOK_SECRET=.*/WEBHOOK_SECRET=$(openssl rand -hex 32)/" config/glitch.conf
./apply.sh
grep WEBHOOK_SECRET config/glitch.conf
```

### Serving and Webhooks

Caddy forwards each project's requests to its web service on the `web` network, as `<name>-<service>`, compresses responses, and sends the visitor's address in an `X-Real-IP` header. On a staging server, every project site and redirect also sends `X-Robots-Tag: noindex, nofollow`.

The webhook answers:

| Request | Response |
|---------|----------|
| A push to the branch this server deploys | 200, "Deploy of `<project>` `<branch>` requested" |
| A push to another branch, or GitHub's ping | 200, "Ignored `<ref>`" |
| Signed with the wrong secret | 500 |
| Not signed | 403 |
| A project not on this server | 404 |

### Maintenance Pages

When a project can't be reached, or its web service answers 502 or 504 (such as nginx finding its PHP container unreachable), Caddy shows a maintenance page instead of a bare error. Requests are never held or retried, so no visitor uses a site whose containers are being replaced, for example while a starting container runs migrations. The page keeps the error's status code, is sent with `Retry-After: 30` and `Cache-Control: no-store`, and reloads itself. Other errors, such as a 500 from a bug or a 503 from the application itself, pass through unchanged.

| Page | Shown |
|------|-------|
| `updating.html` | While a [deploy](#deploys) replaces the project's containers and waits for them to be ready |
| `unavailable.html` | At any other time |

The shared pages are in `caddy/pages/`. A project can show its own instead by adding `maintenance/updating.html`, `maintenance/unavailable.html`, or both to its repository; each deploy copies them from the deployed commit into `generated/maintenance/<name>/`, and a page the project doesn't have falls back to the shared one. A page must be self-contained, with its styles and images inline, since nothing else can be loaded while the site is down.

### Databases

Projects can share one database server, `shared-mariadb`, rather than each running its own, which matters on a small server. Each project that uses it gets its own database and user, both named after the project with `_` in place of `-` (`old-wiki` becomes `old_wiki`), and the user can reach only that database. A project uses it when its config file has a `DATABASE_PASSWORD`, the password of its user. Adding a project whose [setup.conf](#project-setup) asks for the database adds one; for another project, add it yourself:

```bash
echo "DATABASE_PASSWORD=$(openssl rand -hex 24)" >> config/glitch.conf
./apply.sh
./deploy.sh glitch
```

Each deploy of such a project prepares its database before building anything:

- The database starts if it isn't running, the first time with the root password setup generated as `MARIADB_ROOT_PASSWORD` in `.env`. A server without such a project never runs it.
- Its network, `<name>-database`, is created, and the database is connected to it. Every service of the project joins it, and reaches the database there as `shared-mariadb` on port 3306. Only this project's containers are on the network, so no project can reach another's containers through the database. The network is internal, so nothing on it reaches the internet.
- The project's database and user are created if they don't exist yet, and the user's password is set to the one in the config file, so changing it there and deploying changes it.
- If the deploy just created the database, and the project's `setup.conf` names a [schema](#project-setup), it runs in the new database, as the project's own user, so it can change nothing outside that database. A database that already exists is never touched, so a schema never runs against existing data, whatever it contains. If the schema fails, the new database is dropped again, and the deploy stops with the old containers still running, so the next deploy starts over.

Running setup again updates the database with the other shared services, if it is running, and connects it to each project's network again, since a replaced container loses them. Projects lose their connections to it for the few seconds that takes. A new MariaDB version upgrades the data files when it starts.

`database.sh` works with the database by hand:

| Command | Effect |
|---------|--------|
| `./database.sh shell` | Opens a MariaDB shell as root |
| `./database.sh shell <name>` | Opens a MariaDB shell as root in the project's database |
| `./database.sh dump <name> > <name>.sql` | Writes the project's database as SQL |
| `./database.sh import <name> < <name>.sql` | Runs SQL in the project's database, such as a dump from another server |

Removing a project keeps its database, and prints the SQL that deletes it.

## Deploys

`./deploy.sh <name>` deploys a project:

1. Clones its repository into `projects/<name>` the first time, then fetches the latest commit of its branch and checks it out. Changes to tracked files in the clone are discarded; untracked files, such as the project's own `.env`, are kept. The running containers never read the clone, so this changes nothing on the site.
2. Fills in any values the commit's [setup.conf](#project-setup) asks for that can be generated, and copies the project's env files from `config/<name>/` into the clone. If a value has to be entered by hand, the deploy stops, and the old containers keep running.
3. Writes `generated/projects/<name>/compose.server.yml`, which connects the project's web service to the shared `web` network as `<name>-<service>`, and tags each image the project builds with the commit (see [Images](#images)). Nothing else in the project joins the shared network, so projects cannot reach each other's databases. If the project uses the [shared database](#databases), the file also connects its services to the project's database network.
4. Refuses to deploy if the project mounts files tracked in its repository into a container (see [Images](#images)).
5. If the project uses the [shared database](#databases), starts the database if it isn't running, connects it to the project's network, and creates the project's database and user. If this fails, the old containers keep running.
6. Pulls the images the project doesn't build, if they are missing, and builds the rest, while the old containers keep serving the site. If either fails, the old containers keep running.
7. Copies the project's own [maintenance pages](#maintenance-pages) from the commit, if it has any, and turns on the updating page. Then it replaces the containers with `docker compose up --no-build`, using the project's Compose file and the generated one. The Compose project is named after the project. While the containers are replaced, visitors who reach the site see the updating page.
8. Waits up to 5 minutes until every container is running and passes its health check, if it has one. A container that exits on its own with status 0, such as a one-off migration, counts as done. Then it turns the updating page off. If a container is unhealthy or exits with an error, the deploy fails and prints the command to [roll back](#rolling-back).
9. Records the commit in `generated/projects/<name>/releases`, and removes the images of all but the three newest releases.
10. Deploys again if more commits were pushed in the meantime.

Two deploys of the same project never overlap. On a server, the webhook starts them: `project-deploy@<name>.path` sees the project's trigger file change and starts `project-deploy@<name>.service`, which runs `deploy.sh` as root.

```bash
systemctl start project-deploy@glitch     # deploy by hand
journalctl -u project-deploy@glitch -f    # follow its deploys
```

On your own computer, run `./deploy.sh <name>` yourself, or `./deploy.sh --watch` to deploy whenever the webhook asks, as a server does. To test a change before pushing it, add the project with its local clone as `--repo`, commit the change there, and deploy.

### Images

A server runs each project only from images built from one commit. Each image the project builds is tagged `<name>-<service>:<commit>`, with the first 12 characters of the commit, and labeled with the full commit as `org.opencontainers.image.revision`. Checking out a commit, or any other change to files on the server, has no effect on a running site until its containers are replaced.

So a deploy refuses a project whose Compose configuration mounts files tracked in its repository: a bind mount of a tracked file, a directory with tracked files in it, or the whole clone, and configs or secrets read from tracked files. A mounted directory would change the running site as soon as the clone checks out a new commit, before the new images are built. Files the repository doesn't track, such as a `.env` holding secrets, can still be mounted, preferably read-only. Mounts for local development belong in `docker-compose.override.yml`, which deploys leave out.

To see which commit each container runs:

```bash
docker ps --format '{{.Names}}\t{{.Label "org.opencontainers.image.revision"}}'
cat generated/projects/glitch/releases    # deployed commits, newest last
```

### Rolling Back

The images of the three newest releases are kept. To go back to an earlier one, deploy its commit:

```bash
./deploy.sh glitch 3f9c2a1b7d4e
```

The commit must be on the project's branch. Its images are usually still there, so the build takes seconds. The next push to the branch deploys its latest commit again, so push a fix or a revert to stay on the old version. Changes the newer release made to data, such as database migrations, are not undone.

## Preparing a Project

A project's repository needs a few things to run on a server:

| Convention | Why |
|------------|-----|
| A `docker-compose.yml` or `compose.yaml` at the top of the repository that builds everything from the repository | The server builds each project itself; there is no container registry |
| A service named `nginx` that serves HTTP on port 80, or another service and port given with `--upstream` | Only this service joins the shared network, and Caddy sends it every request |
| No `container_name` | Compose names containers after the project, such as `glitch-nginx-1`, so projects never clash |
| No published ports in `docker-compose.yml`; put ports for local development in `docker-compose.override.yml` | Only Caddy listens on ports 80 and 443. Deploys leave out the override file. |
| No external networks, and services reach each other by service name, such as `php:9000` | Each project gets its own private network, and the server adds the shared one |
| The visitor's address read from the `X-Real-IP` header | Caddy sends it, with the real address even behind Cloudflare |
| Exact versions for base images, such as `php:8.4.27-fpm-alpine` | Deploys build with Docker's cache and never pull newer images, so a new version is a reviewed commit |
| Optionally, its own `maintenance/updating.html` and `maintenance/unavailable.html`, each self-contained | Caddy shows them instead of the shared [maintenance pages](#maintenance-pages) |
| Code built into the images, never mounted from the repository; put mounts for local development in `docker-compose.override.yml` | Servers run each project only from images built from one commit, and deploys refuse tracked files mounted into a container (see [Images](#images)) |
| A `setup.conf`, if it needs env files with secrets or settings for this server (see [Project Setup](#project-setup)) | Projects are added and deployed without editing files on the server by hand |
| A `.dockerignore` that leaves out `.git` and every `.env` file | Secrets reach containers at run time, through `env_file` or a read-only mount of an untracked file, never inside an image |
| A database, if it needs one, from the [shared database](#databases) on servers: `shared-mariadb` on port 3306, with the project's database name, user, and password. A database service for local development belongs in `docker-compose.override.yml`. | Projects share one database server rather than each running their own |
| A `healthcheck` on long-running services, especially the web service | Deploys wait for the new containers to pass it, and fail if one doesn't |
| nginx looking up the PHP service through Docker's DNS every few seconds, as below | A deploy can replace the PHP container, which changes its address; nginx otherwise keeps the address it found when it started |

**docker-compose.yml for a project with nginx and PHP**

```yaml
services:
  nginx:
    build:
      context: .
      dockerfile: Dockerfile.nginx
    restart: unless-stopped
  php:
    build:
      context: .
      dockerfile: Dockerfile.php
    restart: unless-stopped
```

**nginx.conf: passing PHP requests on, finding the PHP container again after a deploy, and reading the visitor's address**

```nginx
set_real_ip_from 10.0.0.0/8;
set_real_ip_from 172.16.0.0/12;
set_real_ip_from 192.168.0.0/16;
real_ip_header X-Real-IP;

# Docker's DNS server; a variable in fastcgi_pass makes nginx look the
# address up again when it expires, instead of once at startup
resolver 127.0.0.11 valid=5s ipv6=off;
set $php_upstream php:9000;

location ~ \.php$ {
    fastcgi_pass $php_upstream;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
}
```

## Files

Each server has three kinds of files that are never committed:

| Where | Written by | Contents |
|-------|------------|----------|
| `.env` and `config/` | Setup, `add-project.sh`, `configure-project.sh`, or you | What this server is, which projects it runs, and their env files |
| `generated/` | The scripts | Everything derived from those settings. Never edit it by hand: change `.env` or `config/` and run `apply.sh` instead. |
| `projects/` | Deploys | One clone per project |

`.env`, written by setup:

| Setting | Purpose |
|---------|---------|
| `SERVER_HOSTNAME` | The server's own hostname. Its DNS record must point at the server before Caddy can obtain its certificate. |
| `SERVER_ENVIRONMENT` | `staging` or `production` |
| `UID`, `GID` | The user the webhook container runs as, so it can write trigger files: `deploy` on a server, or you in a local copy |
| `MARIADB_ROOT_PASSWORD` | The root password of the [shared database](#databases), generated by setup. The database keeps the password it was created with, so never change it. |

`config/` holds one `<name>.conf` per project, and in `config/<name>/` the env files of each project with a `setup.conf`; see [Configuration Files](#configuration-files) and [Project Setup](#project-setup).

`generated/`, written by the scripts. Running setup again recreates all of it except Cloudflare-only mode's allowlist:

| Path | Contents |
|------|----------|
| `generated/caddy/global/` | Server-wide Caddy settings, such as Cloudflare-only mode's trusted proxies |
| `generated/caddy/sites/` | One Caddy site file per project |
| `generated/caddy/hostname/` | What the server's own hostname serves besides the webhooks |
| `generated/webhook/hooks.json` | The webhook definitions, with each project's secret |
| `generated/triggers/` | One trigger file per project, written by the webhook to request a deploy |
| `generated/projects/` | Per project: the Compose file each deploy adds, connecting the project to the shared network and tagging its images with the commit, and `releases`, the commits deployed, newest last |
| `generated/maintenance/` | Per project: its own maintenance pages, copied by each deploy, and the `deploying` flag that shows the updating page |
| `generated/locks/` | Lock files that keep deploys of the same project from overlapping |
| `generated/cloudflare/` | Cloudflare-only mode's address ranges, as last downloaded, and its allowlist |
