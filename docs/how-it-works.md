# How It Works

On a server, every command here runs as root. On your own computer, the same commands run as you, against a [local copy](#a-local-copy-for-testing).

## Shared Services

Every server runs two containers from this repository's `docker-compose.yml`:

| Container | Purpose |
|-----------|---------|
| `shared-caddy` | Terminates HTTPS on ports 80 and 443 for the server's own hostname and every project's domains, obtaining certificates automatically, and shows a [maintenance page](#maintenance-pages) when a project can't answer. `caddy/Caddyfile` imports the configuration the scripts write to `generated/caddy/`. |
| `shared-webhook` | Receives GitHub push webhooks at `/hooks/<project>`. A request signed with that project's secret, for a push to the branch the server deploys, writes the project's trigger file in `generated/triggers/`. It has no Docker access. |

Both join the `web` Docker network, which each project's web service joins too. The Compose project is named `shared`, so its volumes are `shared_caddy_data` and `shared_caddy_config`.

The server's own hostname (`SERVER_HOSTNAME`, such as `stage.wetfish.net`) receives the webhooks for every project at `/hooks/`. Every other path goes to the project whose domains include the hostname, or, if none does, answers `OK` for checking that the server is up. It always sends `X-Robots-Tag: noindex, nofollow` so search engines leave it out.

## Setup

`setup.sh` runs as root on Debian 13 or Ubuntu and is safe to re-run. It:

1. Clones this repository into `/srv/wetfish-server` when run by itself (piped from curl, or saved as a lone file), then continues with the clone's own copy of the script. Run from a clone, it uses that clone wherever it is.
2. Asks for the server's hostname, whether it is a staging or production server, and whether to turn on [Cloudflare-only mode](cloudflare.md), before any long-running step.
3. Installs git, curl, and jq, then Docker Engine and the Compose plugin from Docker's apt repository, and caps container logs at 100 MB each with Docker's `local` log driver, unless `/etc/docker/daemon.json` already exists.
4. Adds a 1 GiB swap file if the server has less than 2 GiB of memory and no swap.
5. Creates the `deploy` user, which has no password or login shell; the webhook listener runs as this user.
6. Allows ports 80 and 443 in ufw, if ufw is active.
7. Writes `.env`, creates `config/` and `generated/`, installs the systemd units that run [deploys](#deploys), applies the [project configuration](#projects), and builds and starts the shared services.
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

It writes `config/<name>.conf` with a new webhook secret, applies the configuration, deploys the project for the first time, and prints the webhook to add in GitHub, under the repository's Settings → Webhooks: the payload URL, content type `application/json`, the secret, and only the push event. If the project cannot be added, for example because another project already uses one of its domains, nothing changes. If only its first deploy fails, the project stays added: fix the problem and run `./deploy.sh <name>`.

Remove a project with `./remove-project.sh <name>`, which asks to confirm unless given `--yes`. It stops the project's containers; its domains stop being served and its webhook stops working, so delete the webhook in GitHub too. Its clone in `projects/<name>` and its Docker volumes are kept.

### Configuration Files

`config/` is never committed, so every server keeps its own list of projects. Each `config/<name>.conf` is readable only by its owner, because it holds the webhook secret:

```ini
REPO=https://github.com/wetfish/glitch.git
DOMAINS=stage-glitch.wetfish.net
WEBHOOK_SECRET=3f9c...
```

The other settings are `BRANCH`, `REDIRECTS`, and `UPSTREAM`, matching the options above. Domains are separated by spaces.

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

## Deploys

`./deploy.sh <name>` deploys a project:

1. Clones its repository into `projects/<name>` the first time, then fetches the latest commit of its branch and checks it out. Changes to tracked files in the clone are discarded; untracked files, such as the project's own `.env`, are kept. The running containers never read the clone, so this changes nothing on the site.
2. Writes `generated/projects/<name>/compose.server.yml`, which connects the project's web service to the shared `web` network as `<name>-<service>`, and tags each image the project builds with the commit (see [Images](#images)). Nothing else in the project joins the shared network, so projects cannot reach each other's databases.
3. Refuses to deploy if the project mounts files tracked in its repository into a container (see [Images](#images)).
4. Pulls the images the project doesn't build, if they are missing, and builds the rest, while the old containers keep serving the site. If either fails, the old containers keep running.
5. Copies the project's own [maintenance pages](#maintenance-pages) from the commit, if it has any, and turns on the updating page. Then it replaces the containers with `docker compose up --no-build`, using the project's Compose file and the generated one. The Compose project is named after the project. While the containers are replaced, visitors who reach the site see the updating page.
6. Waits up to 5 minutes until every container is running and passes its health check, if it has one. A container that exits on its own with status 0, such as a one-off migration, counts as done. Then it turns the updating page off. If a container is unhealthy or exits with an error, the deploy fails and prints the command to [roll back](#rolling-back).
7. Records the commit in `generated/projects/<name>/releases`, and removes the images of all but the three newest releases.
8. Deploys again if more commits were pushed in the meantime.

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
| A `.dockerignore` that leaves out `.git` and every `.env` file | Secrets reach containers at run time, through `env_file` or a read-only mount of an untracked file, never inside an image |
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
| `.env` and `config/` | Setup, `add-project.sh`, or you | What this server is and which projects it runs |
| `generated/` | The scripts | Everything derived from those settings. Never edit it by hand: change `.env` or `config/` and run `apply.sh` instead. |
| `projects/` | Deploys | One clone per project |

`.env`, written by setup:

| Setting | Purpose |
|---------|---------|
| `SERVER_HOSTNAME` | The server's own hostname. Its DNS record must point at the server before Caddy can obtain its certificate. |
| `SERVER_ENVIRONMENT` | `staging` or `production` |
| `UID`, `GID` | The user the webhook container runs as, so it can write trigger files: `deploy` on a server, or you in a local copy |

`config/` holds one `<name>.conf` per project; see [Configuration Files](#configuration-files).

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
