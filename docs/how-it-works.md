# How It Works

## Shared Services

Every server runs two containers from this repository's `docker-compose.yml`:

| Container | Purpose |
|-----------|---------|
| `shared-caddy` | Terminates HTTPS on ports 80 and 443 for the server's own hostname and every project's domains, obtaining certificates automatically. `caddy/Caddyfile` imports the configuration generated on the server from `state/caddy/`. |
| `shared-webhook` | Receives GitHub push webhooks at `/hooks/<project>`. A request signed with that project's secret, for a push to the branch the server deploys, writes the project's trigger file in `state/triggers/`. It has no Docker access. |

Both join the `web` Docker network, which project web servers join too. The Compose project is named `shared`, so its volumes are `shared_caddy_data` and `shared_caddy_config`.

The server's own hostname (`SERVER_HOSTNAME`, such as `stage.wetfish.net`) receives the webhooks for every project and answers `OK` on every other path, for checking that the server is up. It sends `X-Robots-Tag: noindex, nofollow` so search engines leave it out. Until projects are added, `/hooks/` answers 404, "Hook not found."

## Setup

`setup.sh` runs as root on Debian 13 or Ubuntu and is safe to re-run. It:

1. Clones this repository into `/srv/wetfish-server` when run by itself (piped from curl, or saved as a lone file), then continues with the clone's own copy of the script. Run from a clone, it uses that clone wherever it is.
2. Asks for the server's hostname and whether to turn on [Cloudflare-only mode](cloudflare.md), before any long-running step.
3. Installs Docker Engine and the Compose plugin from Docker's apt repository, and caps container logs at 100 MB each with Docker's `local` log driver, unless `/etc/docker/daemon.json` already exists.
4. Adds a 1 GiB swap file if the server has less than 2 GiB of memory and no swap.
5. Creates the `deploy` user, which has no password or login shell, and adds it to the `docker` group.
6. Allows ports 80 and 443 in ufw, if ufw is active.
7. Writes `.env`, creates `state/`, and builds and starts the shared services.
8. Turns on Cloudflare-only mode, if chosen.

| Option | Effect |
|--------|--------|
| `--hostname <name>` | Sets the server's hostname without asking |
| `--cloudflare` | Turns on Cloudflare-only mode without asking |
| `--no-cloudflare` | Leaves Cloudflare-only mode off without asking |

Options also work when piping from curl:

```bash
curl -fsSL https://raw.githubusercontent.com/wetfish/server/main/setup.sh | sudo bash -s -- --hostname stage.example.com --no-cloudflare
```

Without a terminal to ask on, a missing hostname is an error and Cloudflare-only mode stays off. On a re-run, the hostname in `.env` is kept unless `--hostname` is given, and Cloudflare-only mode, if on, is applied again.

## Files

The clone is owned by root, and its scripts run with `sudo`. The `deploy` user owns only what deploys write.

`.env`, written by setup and never committed:

| Setting | Purpose |
|---------|---------|
| `SERVER_HOSTNAME` | The server's own hostname. Its DNS record must point at the server before Caddy can obtain its certificate. |
| `UID`, `GID` | The `deploy` user's IDs, which the webhook container runs as so it can write trigger files |

`state/`, generated on the server and never committed:

| Path | Contents |
|------|----------|
| `state/caddy/global/` | Server-wide Caddy settings, such as Cloudflare-only mode's trusted proxies |
| `state/caddy/sites/` | One Caddy site file per project |
| `state/webhook/hooks.json` | The webhook definitions, with each project's secret |
| `state/triggers/` | One trigger file per project, written by the webhook to request a deploy; owned by `deploy` |
| `state/cloudflare/` | Cloudflare-only mode's address ranges, as last downloaded, and its allowlist |

## Trying It Locally

The shared services run on any machine with Docker. With `SERVER_HOSTNAME=localhost`, Caddy uses its own local certificate authority instead of Let's Encrypt:

```bash
cp .env.example .env
mkdir -p state/caddy/global state/caddy/sites state/webhook state/triggers
docker compose up -d --build
curl -k https://localhost/
```

Create `state/` first; otherwise Docker creates it owned by root, and the webhook cannot write trigger files.
