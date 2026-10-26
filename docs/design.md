# Design Decisions

Each choice favors what a small community can afford and understand.

**Docker Compose, not Kubernetes.** We ran our sites on Kubernetes for a while, and it made things more complicated and more expensive. Compose runs the same files on a laptop and on a server, and anyone who knows Docker can read them.

**Builds happen on the server.** There are no GitHub Actions, build servers, or container registry: the server clones each project and builds it with `docker compose build`. Builds use the server's own CPU, but Docker's layer cache keeps routine deploys quick.

**Servers run code only from images.** Each deploy builds images from one commit, tagged with it, while the old containers keep serving, and replaces the containers only once the build succeeds. Code mounted from the clone would change the running site the moment a commit is checked out, before anything is built, so deploys refuse it; mounting code is for local development only. Keeping the last three releases' images makes a rollback a quick redeploy of an earlier commit.

**Webhooks, not polling.** We used to run Watchtower, which polls a registry for new images and is now deprecated. A webhook starts a deploy within seconds of a push, and between pushes the server does nothing.

**One webhook per project.** Each project gets its own webhook URL (`/hooks/<project>`) and secret. A repository's maintainers, at Wetfish or another organization, add its webhook themselves, so nobody needs access to anyone else's GitHub organization. A leaked secret only lets someone redeploy that project from its own branch.

**The webhook listener cannot touch Docker.** It is the only part of the deploy system reachable from the internet, so it only checks signatures and writes trigger files; systemd on the host runs the deploys. Docker access is equivalent to root access, so the listener never gets it.

**Each server keeps its own project list.** A server's projects, domains, and webhook secrets live in its own `config/` directory, never in this repository, so anyone can run their own set of sites without changing it, and moving to a new server means copying `config/` and running setup.

**Projects stay independent.** Each project keeps its own repository, Dockerfile, and language version, and runs from its own clone. Upgrading PHP in one never forces an upgrade in another. This repository never pins project versions: a server runs the latest commit of the branch it deploys.

**Projects plug in with plain Compose.** A project needs only a Compose file with a web service. The server connects that one service to its shared network itself, so the same file runs on a laptop and on a server, and projects stay unaware of each other.

**Shared containers are named apart.** Containers from this repository are named `shared-<service>`, and a project's containers are named after the project (`wiki-app`, `wiki-nginx`), so `docker ps` shows what belongs to whom.

**Maintenance pages, not held requests.** While a deploy replaces a project's containers, Caddy answers right away with a page saying the site is being updated, rather than holding requests until the new containers answer. A held request could reach the new site while a starting container is still running migrations against a shared database, so no visitor uses a site mid-switch.

**One proxy, no other published ports.** Only Caddy listens on ports 80 and 443, and it obtains certificates automatically. Projects join the shared `web` network instead of publishing ports, which matters because Docker's published ports bypass host firewalls such as ufw.

**Small servers are the target.** Setup adds swap to servers with less than 2 GiB of memory, so builds don't run out of memory, and caps container logs, which once filled a production disk of ours.

**Staging is its own server.** Updates are tested in a production-like environment for the price of one more small server.

**Cloudflare is optional.** [Cloudflare-only mode](cloudflare.md) hides a server behind Cloudflare, but it is off unless you turn it on, so nobody has to depend on one company to run their sites.

**MIT license.** The scripts and configuration can be copied into projects under any license, including those of the partner organizations that share our servers.
