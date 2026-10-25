# How It Works

On a server, every command here runs as root. On your own computer, the same commands run as you, against a [local copy](#a-local-copy-for-testing).

## Shared Services

Every server runs two containers from this repository's `docker-compose.yml`:

| Container | Purpose |
|-----------|---------|
| `shared-caddy` | Terminates HTTPS on ports 80 and 443 for the server's own hostname and every project's domains, obtaining certificates automatically. `caddy/Caddyfile` imports the configuration the scripts write to `generated/caddy/`. |
| `shared-webhook` | Receives GitHub push webhooks at `/hooks/<project>`. A request signed with that project's secret, for a push to the branch the server deploys, writes the project's trigger file in `generated/triggers/`. It has no Docker access. |

Both join the `web` Docker network, which each project's web service joins too. The Compose project is named `shared`, so its volumes are `shared_caddy_data` and `shared_caddy_config`.

The server's own hostname (`SERVER_HOSTNAME`, such as `stage.wetfish.net`) receives the webhooks for every project at `/hooks/`. Every other path goes to the project whose domains include the hostname, or, if none does, answers `OK` for checking that the server is up. It always sends `X-Robots-Tag: noindex, nofollow` so search engines leave it out.

## Setup

`setup.sh` runs as root on Debian 13 or Ubuntu and is safe to re-run. It:

1. Clones this repository into `/srv/wetfish-server` when run by itself (piped from curl, or saved as a lone file), then continues with the clone's own copy of the script. Run from a clone, it uses that clone wherever it is.
2. Asks for the server's hostname, whether it is a staging or production server, and whether to turn on [Cloudflare-only mode](cloudflare.md), before any long-running step.
3. Installs Docker Engine and the Compose plugin from Docker's apt repository, and caps container logs at 100 MB each with Docker's `local` log driver, unless `/etc/docker/daemon.json` already exists.
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

Run as yourself from a clone, `setup.sh` sets up a local copy instead, for trying projects on your own computer before they reach a server. It needs Docker, usable without sudo, and ports 80 and 443 free:

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

## Deploys

`./deploy.sh <name>` deploys a project:

1. Clones its repository into `projects/<name>` the first time, then fetches the latest commit of its branch and checks it out. Changes to tracked files in the clone are discarded; untracked files, such as the project's own `.env`, are kept.
2. Writes `generated/projects/<name>/compose.server.yml`, which connects the project's web service to the shared `web` network as `<name>-<service>`. Nothing else in the project joins it, so projects cannot reach each other's databases.
3. Builds and starts the project's containers with `docker compose up --build`, using the project's Compose file and that one. The Compose project is named after the project.
4. Deploys again if more commits were pushed in the meantime.

Two deploys of the same project never overlap. On a server, the webhook starts them: `project-deploy@<name>.path` sees the project's trigger file change and starts `project-deploy@<name>.service`, which runs `deploy.sh` as root.

```bash
systemctl start project-deploy@glitch     # deploy by hand
journalctl -u project-deploy@glitch -f    # follow its deploys
```

On your own computer, run `./deploy.sh <name>` yourself, or `./deploy.sh --watch` to deploy whenever the webhook asks, as a server does. To test a change before pushing it, add the project with its local clone as `--repo`, commit the change there, and deploy.

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

**nginx.conf: passing PHP requests on and reading the visitor's address**

```nginx
set_real_ip_from 10.0.0.0/8;
set_real_ip_from 172.16.0.0/12;
set_real_ip_from 192.168.0.0/16;
real_ip_header X-Real-IP;

location ~ \.php$ {
    fastcgi_pass php:9000;
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
| `generated/projects/` | The Compose file each deploy adds, connecting the project to the shared network |
| `generated/locks/` | Lock files that keep deploys of the same project from overlapping |
| `generated/cloudflare/` | Cloudflare-only mode's address ranges, as last downloaded, and its allowlist |
