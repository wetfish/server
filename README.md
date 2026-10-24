# Wetfish Server

Runs many independent websites on one small, inexpensive server, and deploys each one automatically when its code is pushed to GitHub.

**Status:** the shared HTTPS proxy, the webhook listener, and the optional Cloudflare-only mode are in place. Server setup, project deploys, shared databases, and backups come next; see the [Roadmap](#roadmap).

> This repository previously held a small Node.js web framework (2015–2016). That code is preserved, under its original GPL-3.0 license, in the `v0.2.0` tag.

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

### Cloudflare is optional

A server can accept web traffic only from Cloudflare's proxies, which hides its address and blocks scans of it (see [Cloudflare-Only Mode](#cloudflare-only-mode)). It is off unless you turn it on, and everything else works the same without it, so nobody has to depend on one company to run their sites.

### MIT license

This repository is MIT licensed, so its scripts and configuration can be copied into, or adapted for, projects under any license, including the partner organizations' projects that share our servers.

## How It Works

Each server runs two shared services from this repository's `docker-compose.yml`:

| Service | Container | Purpose |
|---------|-----------|---------|
| caddy | `shared-caddy` | Terminates HTTPS on ports 80 and 443 for the server's own hostname and every project's domains. Configured by `caddy/Caddyfile`, which imports the files generated on the server from `state/caddy/`: server-wide settings from `state/caddy/global/` and one site file per project from `state/caddy/sites/`. |
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
| `state/caddy/global/` | Server-wide Caddy settings, such as Cloudflare-only mode's trusted proxies |
| `state/caddy/sites/` | One Caddy site file per project |
| `state/webhook/hooks.json` | The webhook definitions, with each project's secret |
| `state/triggers/` | One trigger file per project, written by the webhook to request a deploy |
| `state/cloudflare/` | Cloudflare-only mode's address ranges, as last downloaded, and its allowlist |

## Trying It Locally

The shared services run on any machine with Docker. With `SERVER_HOSTNAME=localhost`, Caddy serves HTTPS with its own local certificate authority instead of Let's Encrypt.

```bash
cp .env.example .env
mkdir -p state/caddy/global state/caddy/sites state/webhook state/triggers
docker compose up -d --build
curl -k https://localhost/
```

Create the `state/` directories before the first `docker compose up`. Otherwise Docker creates them owned by root, and the webhook container cannot write trigger files.

## Cloudflare-Only Mode

Optional. With it on, ports 80 and 443 accept connections only from [Cloudflare's proxies](https://www.cloudflare.com/ips/) (and any addresses you [allow for testing](#testing-without-cloudflare)), so the sites cannot be reached directly by the server's IP address, and scans of that address find nothing. Caddy reads each visitor's real address from the `CF-Connecting-IP` header that Cloudflare sends, so access logs and `{client_ip}` show visitors rather than Cloudflare. SSH and every other port are untouched.

### Before Turning It On

The mode covers the whole server, so every domain on it must go through Cloudflare first. Anything else becomes unreachable, including Let's Encrypt checking a domain that is not proxied.

1. **Proxy every domain on the server,** including the server's own hostname, which GitHub's webhooks reach: in Cloudflare's DNS settings, each record pointing at the server must be **Proxied** (orange cloud).
2. **Set SSL/TLS encryption to Full (strict).** Cloudflare then connects to the server over HTTPS and checks Caddy's certificate. With Flexible, Cloudflare connects over plain HTTP and Caddy's redirect to HTTPS loops forever.
3. **Turn off Always Use HTTPS** (SSL/TLS → Edge Certificates). Caddy already redirects HTTP to HTTPS itself. Let's Encrypt checks new domains over plain HTTP, which Cloudflare must pass through to Caddy rather than redirect.
4. **Keep subdomains one level deep,** such as `stage-wiki.example.com` rather than `wiki.stage.example.com`. Cloudflare's free certificate covers `example.com` and `*.example.com` only.

### Commands

```bash
sudo ./cloudflare.sh enable     # turn it on, or re-apply it
sudo ./cloudflare.sh status     # show whether it is on, when the ranges were downloaded, and the allowlist
sudo ./cloudflare.sh update     # download Cloudflare's address ranges again now
sudo ./cloudflare.sh disable    # turn it off
```

`enable` installs `nftables` and `curl` if they are missing. Run `disable` before changing a domain back to DNS only, or that domain becomes unreachable.

### Testing Without Cloudflare

Sometimes a developer needs to reach the server directly, bypassing Cloudflare. There are two ways.

**An SSH tunnel** needs no changes on the server and works from any network. The firewall never filters the server's own connections, so a tunnel to its port 443 reaches Caddy. Connect to the server's real address or an SSH host alias, since a proxied domain resolves to Cloudflare:

```bash
ssh -L 8443:localhost:443 <server-address>
curl --resolve stage-wiki.example.com:8443:127.0.0.1 https://stage-wiki.example.com:8443/
```

**The allowlist** lets a specific address or range reach ports 80 and 443 directly:

```bash
sudo ./cloudflare.sh allowlist add 203.0.113.7       # IPv4 or IPv6, an address or a range
sudo ./cloudflare.sh allowlist remove 203.0.113.7
sudo ./cloudflare.sh allowlist                       # show the list (status shows it too)
```

`remove` only takes an address off the allowlist; it never blocks anything. Addresses that are neither Cloudflare's nor on the allowlist are blocked. Allowed addresses are not trusted to send `CF-Connecting-IP`, so Caddy logs them as themselves. The allowlist is kept through the weekly updates and reboots, and cleared by `disable`.

Either way, the domain's DNS points at Cloudflare, so point it at the server for the test: `curl --resolve`, as above, or a line in your hosts file. Caddy's certificate is valid for the domain, so browsers show no warnings.

### How It Works

- **Firewall:** `cloudflare/firewall.nft`, with Cloudflare's address ranges and the allowlist filled in, is installed as `/etc/cloudflare-only.nft` and loaded at boot, before Docker starts, by `cloudflare-firewall.service`. Its rules live in an nftables table of their own (`cloudflare_only`), so they never change Docker's rules or any other firewall on the server. They drop connections to ports 80 and 443 from anywhere but Cloudflare and the allowlist, both those Docker forwards to Caddy and those to the server itself.
- **Real visitor addresses:** `cloudflare/trusted-proxies.Caddyfile`, with the same ranges filled in, is written to `state/caddy/global/cloudflare.Caddyfile`, telling Caddy to trust the `CF-Connecting-IP` header from Cloudflare. Private network ranges are trusted too, because Docker hands Caddy IPv6 connections through its userland proxy, which makes them appear to come from the Docker network; the firewall ensures those connections come from Cloudflare as well.
- **Keeping the ranges current:** `cloudflare-update.timer` downloads Cloudflare's lists once a week and applies any change in one step. A failed download or a list that does not look like address ranges keeps the current ranges, and Caddy settings it rejects are never left in place, so an update cannot lock out Cloudflare or break Caddy. Check its runs with `journalctl -u cloudflare-update`.

Starting Debian's `nftables.service` by hand (`systemctl restart nftables`) flushes every firewall rule on the server, including these and Docker's. If that happens, restart both: `sudo systemctl restart cloudflare-firewall docker`.

## Roadmap

Still to come, in this order:

1. **Server setup:** a `setup.sh` that installs Docker on Debian 13, creates the deploy user, writes `.env`, starts the shared services, and installs the systemd units that run deploys.
2. **Projects:** adding a project (cloning it, registering its webhook and Caddy site) and the deploy script that runs on each push.
3. **Shared databases:** optional `shared-mariadb` and `shared-postgres` containers for projects that use the same database engine, each project with its own database and user. Projects keep their own database container for local development, and can keep one on a server when they need a different engine or version.
4. **Backups:** database dumps and uploads synced to object storage.

## License

MIT; see `LICENSE`.
