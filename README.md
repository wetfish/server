# Wetfish Server

Runs many independent websites on one small, inexpensive server, and deploys each one automatically when its code is pushed to GitHub.

**Status:** the shared HTTPS proxy and webhook listener are in place. Server setup, project deploys, shared databases, and backups come next; see the [Roadmap](#roadmap).

> This repository previously held a small Node.js web framework (2015–2016). That code is preserved in the `v0.2.0` tag.

## Why We Built This

Wetfish is a small internet community that has maintained a network of open-source projects for decades. We run them on low-cost hardware, typically a virtual server for around $5 a month, and we intend to keep it that way.

We don't want to be the next Facebook. The internet used to be great because it was a way to connect with people all over the world. These days, giant corporate platforms have consolidated the internet into systems that control the flow of information and pit people against each other to farm engagement. We want to promote the old internet: the truly decentralized, grassroots internet, made of many small communities that each respect their own privacy and values.

To make the most impact, we focus on systems that anyone can replicate. Everything here is open source and runs on the cheapest servers available, because a low hosting cost lowers the barrier for people to run their own websites and communities. We want to inspire you to start your own community, and if this repository helps you do that, it worked.

## What It's For

- **Many projects on one server.** Each project lives in its own repository with its own `docker-compose.yml`. A server runs any number of them side by side behind one HTTPS proxy.
- **Deploys on push.** A push to a project's branch sends a GitHub webhook to the server, which pulls the change and rebuilds that project.
- **Staging and production.** Two servers with the same setup: staging deploys each project's `main` branch and production deploys `release`, so every change runs in a production-like environment before it goes live.
- **Different servers for different groups.** Each server runs its own set of projects. Wetfish's sites run on one server, and a partner organization can run its projects on another with the same tools.

## Design Decisions

Every decision below favors what a small community can afford and understand over what a large company would build.

### Docker Compose instead of Kubernetes

We ran our sites on Kubernetes for a while. It made things more complicated and more expensive, and deploying a change needed a build pipeline and a container registry. Docker Compose runs the same files on a laptop and on a server, and anyone who knows Docker can read them.

### Builds happen on the server

There are no GitHub Actions, no build servers, and no container registry. The server clones each project and builds its images with `docker compose build`. Nothing sits between a repository and the servers that run it, and no outside account or paid build minutes are needed.

The trade-off is that builds use the server's own CPU. Docker's layer cache keeps routine deploys quick; only a change to a project's Dockerfile rebuilds its image from scratch.

### Webhooks instead of polling

We used to run Watchtower, which polls a registry for new images and is now deprecated. A webhook starts a deploy within seconds of a push, and between pushes the server does nothing.

### One webhook per project

Each project registered on a server gets its own webhook URL (`/hooks/<project>`) and its own secret. The people who maintain a repository, whether that's Wetfish or another organization, add its webhook themselves; nobody needs administrative access to anyone else's GitHub organization, and repositories that are not on a server are never touched. A leaked secret only lets someone redeploy that one project from what is already on its branch.

### The webhook listener cannot touch Docker

The listener is the only part of the deploy system reachable from the internet, so it has as little power as possible: it checks the request's signature and writes a trigger file. A systemd unit on the host sees the file and runs the deploy. Access to Docker is equivalent to root access, so the listener never gets it.

### Projects stay independent

Each project keeps its own repository, its own Dockerfile, and its own language version, and runs from its own clone on the server. Upgrading PHP in one project never forces an upgrade in another. This repository never pins project versions: a server always runs the latest commit of the branch it deploys, so there is nothing to keep in sync by hand.

### Shared and project containers are named apart

Containers run by this repository are named `shared-<service>` (`shared-caddy`, `shared-webhook`), and a project's containers are named after the project (for example `wiki-app` and `wiki-nginx`). On a server running many projects, `docker ps` shows at a glance which containers serve every project and which belong to one.

### One HTTPS proxy and no other published ports

Caddy is the only container listening on ports 80 and 443. It obtains and renews certificates automatically, and its configuration is short enough to read at a glance. Projects publish no ports; their web servers join the shared `web` network instead. Docker's published ports bypass host firewalls such as ufw, so keeping them to the one proxy keeps the server's exposure easy to see.

### Staging is its own server

Staging runs the same setup on a separate server, so updates are tested in a production-like environment before they go live, at the cost of one more small server.

## How It Works

Each server runs two shared services from this repository's `docker-compose.yml`:

| Service | Container | Purpose |
|---------|-----------|---------|
| caddy | `shared-caddy` | Terminates HTTPS on ports 80 and 443 for the server's own hostname and every project's domains. Configured by `caddy/Caddyfile`, which imports one site file per project from `state/sites/`. |
| webhook | `shared-webhook` | Receives GitHub push webhooks at `/hooks/<project>`. A request signed with that project's secret, for a push to the branch this server deploys, writes the project's trigger file in `state/triggers/`. |

Both join the `web` Docker network, which project web servers join too. The Compose project is named `shared`, so its volumes are named `shared_caddy_data` and `shared_caddy_config` wherever the clone lives.

The server's own hostname (`SERVER_HOSTNAME`, for example `stage.wetfish.net` or `prod.wetfish.net`) receives the webhooks for every project and answers `OK` on every other path, for checking that the server is up. Its responses carry an `X-Robots-Tag: noindex, nofollow` header so search engines leave it out.

Until projects are added, the webhook has no hooks and answers every `/hooks/` request with 404, "Hook not found."

## Server Settings

`.env` (copied from `.env.example`, never committed):

| Setting | Purpose |
|---------|---------|
| `SERVER_HOSTNAME` | This server's own hostname. Its DNS record must point at the server before Caddy can obtain its certificate. |
| `UID`, `GID` | User and group IDs the webhook container runs as: the owner of this clone, so it can write the trigger files. |

Everything generated on a server lives in `state/`, which is never committed:

| Path | Contents |
|------|----------|
| `state/sites/` | One Caddy site file per project |
| `state/webhook/hooks.json` | The webhook definitions, with each project's secret |
| `state/triggers/` | One trigger file per project, written by the webhook to request a deploy |

## Trying It Locally

The shared services run on any machine with Docker. With `SERVER_HOSTNAME=localhost`, Caddy serves HTTPS with its own local certificate authority instead of Let's Encrypt.

```bash
cp .env.example .env
mkdir -p state/sites state/webhook state/triggers
docker compose up -d --build
curl -k https://localhost/
```

Create the `state/` directories before the first `docker compose up`. Otherwise Docker creates them owned by root, and the webhook container cannot write trigger files.

## Roadmap

Still to come, in this order:

1. **Cloudflare-only mode (optional):** accept web traffic only from Cloudflare's proxies, blocking direct access to the server's IP address and IP scans, and pass visitors' real IP addresses on to the projects.
2. **Server setup:** a `setup.sh` that installs Docker on Debian 13, creates the deploy user, writes `.env`, starts the shared services, and installs the systemd units that run deploys.
3. **Projects:** adding a project (cloning it, registering its webhook and Caddy site) and the deploy script that runs on each push.
4. **Shared databases:** optional `shared-mariadb` and `shared-postgres` containers for projects that use the same database engine, each project with its own database and user. Projects keep their own database container for local development, and can keep one on a server when they need a different engine or version.
5. **Backups:** database dumps and uploads synced to object storage.

## License

GPL-3.0; see `LICENSE`.
