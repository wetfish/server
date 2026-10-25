# How It Works

## Shared Services

Every server runs two containers from this repository's `docker-compose.yml`:

| Container | Purpose |
|-----------|---------|
| `shared-caddy` | Terminates HTTPS on ports 80 and 443 for the server's own hostname and every project's domains, obtaining certificates automatically. `caddy/Caddyfile` imports the configuration the scripts write to `generated/caddy/`. |
| `shared-webhook` | Receives GitHub push webhooks at `/hooks/<project>`. A request signed with that project's secret, for a push to the branch the server deploys, writes the project's trigger file in `generated/triggers/`. It has no Docker access. |

Both join the `web` Docker network, which project web servers join too. The Compose project is named `shared`, so its volumes are `shared_caddy_data` and `shared_caddy_config`.

The server's own hostname (`SERVER_HOSTNAME`, such as `stage.wetfish.net`) receives the webhooks for every project at `/hooks/`. Every other path goes to the project whose domains include the hostname, or, if none does, answers `OK` for checking that the server is up. It always sends `X-Robots-Tag: noindex, nofollow` so search engines leave it out.

## Setup

`setup.sh` runs as root on Debian 13 or Ubuntu and is safe to re-run. It:

1. Clones this repository into `/srv/wetfish-server` when run by itself (piped from curl, or saved as a lone file), then continues with the clone's own copy of the script. Run from a clone, it uses that clone wherever it is.
2. Asks for the server's hostname, whether it is a staging or production server, and whether to turn on [Cloudflare-only mode](cloudflare.md), before any long-running step.
3. Installs Docker Engine and the Compose plugin from Docker's apt repository, and caps container logs at 100 MB each with Docker's `local` log driver, unless `/etc/docker/daemon.json` already exists.
4. Adds a 1 GiB swap file if the server has less than 2 GiB of memory and no swap.
5. Creates the `deploy` user, which has no password or login shell, and adds it to the `docker` group.
6. Allows ports 80 and 443 in ufw, if ufw is active.
7. Writes `.env`, creates `config/` and `generated/`, applies the [project configuration](#projects), and builds and starts the shared services.
8. Turns on Cloudflare-only mode, if chosen.

| Option | Effect |
|--------|--------|
| `--hostname <name>` | Sets the server's hostname |
| `--environment staging\|production` | Sets whether this is a staging or production server |
| `--cloudflare` | Turns on Cloudflare-only mode |
| `--no-cloudflare` | Leaves Cloudflare-only mode off |

Options also work when piping from curl:

```bash
curl -fsSL https://raw.githubusercontent.com/wetfish/server/main/setup.sh | sudo bash -s -- --hostname stage.example.com --environment staging --no-cloudflare
```

Without a terminal to ask on, a missing hostname or environment is an error and Cloudflare-only mode stays off. On a re-run, the settings in `.env` are kept unless options change them, and Cloudflare-only mode, if on, is applied again.

## Projects

Each project on a server has a file in `config/`, named after the project. `config/` is never committed, so every server keeps its own list. A project's name becomes its webhook URL, so it may only contain lowercase letters, numbers, and `-`, starting with a letter.

**config/glitch.conf**

```ini
REPO=https://github.com/wetfish/glitch.git
DOMAINS=stage-glitch.wetfish.net
WEBHOOK_SECRET=<generate with: openssl rand -hex 32>
```

| Setting | Purpose |
|---------|---------|
| `REPO` | The project's Git repository (required) |
| `DOMAINS` | Domains the project answers on, separated by spaces (required). Redirects go to the first one. One of them can be the server's own hostname. |
| `WEBHOOK_SECRET` | The secret for the project's GitHub webhook (required) |
| `BRANCH` | The branch to deploy, instead of `main` on staging or `release` on production |
| `REDIRECTS` | Domains that permanently redirect to the first domain, separated by spaces, such as `www.example.com` |
| `UPSTREAM` | The container and port that serve the project, instead of `<project>-nginx:80` |

After adding, changing, or removing a file in `config/`, run `sudo ./apply.sh`. It checks every file first and changes nothing if any has a problem. Then it:

- writes each project's Caddy site to `generated/caddy/sites/<project>.Caddyfile`, and what the server's own hostname serves to `generated/caddy/hostname/`;
- writes each project's webhook, at `https://<SERVER_HOSTNAME>/hooks/<project>`, to `generated/webhook/hooks.json`;
- reloads Caddy, putting the previous files back if Caddy rejects the new ones, and restarts the webhook listener if the webhooks changed;
- prints each project's branch, domains, and webhook URL.

Caddy forwards each project's requests to its `UPSTREAM` on the `web` network, compresses responses, and sends the visitor's address in an `X-Real-IP` header. On a staging server, every project site and redirect also sends `X-Robots-Tag: noindex, nofollow`.

In GitHub, add the webhook under the repository's Settings → Webhooks, with the URL `apply.sh` printed, content type `application/json`, the project's secret, and only the push event. The webhook answers:

| Request | Response |
|---------|----------|
| A push to the branch this server deploys | 200, "Deploy of `<project>` `<branch>` requested" |
| A push to another branch, or GitHub's ping | 200, "Ignored `<ref>`" |
| Signed with the wrong secret | 500 |
| Not signed | 403 |
| A project not on this server | 404 |

## Files

Each server has two kinds of files that are never committed:

| Where | Written by | Contents |
|-----------|------------|----------|
| `.env` and `config/` | You, or setup | What this server is and which projects it runs |
| `generated/` | The scripts | Everything derived from those settings. Never edit it by hand: change `.env` or `config/` and run `apply.sh` instead. |

The clone is owned by root, and its scripts run with `sudo`. The `deploy` user owns only what deploys write.

`.env`, written by setup and never committed:

| Setting | Purpose |
|---------|---------|
| `SERVER_HOSTNAME` | The server's own hostname. Its DNS record must point at the server before Caddy can obtain its certificate. |
| `SERVER_ENVIRONMENT` | `staging` or `production` |
| `UID`, `GID` | The `deploy` user's IDs, which the webhook container runs as so it can write trigger files |

`config/`, written by you and never committed, holds one `<project>.conf` per project, readable only by root because each holds a webhook secret.

`generated/`, written by the scripts. Running setup again recreates all of it except Cloudflare-only mode's allowlist:

| Path | Contents |
|------|----------|
| `generated/caddy/global/` | Server-wide Caddy settings, such as Cloudflare-only mode's trusted proxies |
| `generated/caddy/sites/` | One Caddy site file per project |
| `generated/caddy/hostname/` | What the server's own hostname serves besides the webhooks |
| `generated/webhook/hooks.json` | The webhook definitions, with each project's secret |
| `generated/triggers/` | One trigger file per project, written by the webhook to request a deploy; owned by `deploy` |
| `generated/cloudflare/` | Cloudflare-only mode's address ranges, as last downloaded, and its allowlist |

## Trying It Locally

The shared services run on any machine with Docker. With `SERVER_HOSTNAME=localhost`, Caddy uses its own local certificate authority instead of Let's Encrypt:

```bash
cp .env.example .env
mkdir -p generated/triggers
sudo ./apply.sh
docker compose up -d --build
curl -k https://localhost/
```

Create `generated/triggers/` yourself first; otherwise Docker creates it owned by root, and the webhook cannot write trigger files.
