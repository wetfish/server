# Wetfish Server

Runs many small websites on one inexpensive server, and deploys each one when its code is pushed to GitHub.

## Why

Wetfish is a small internet community that has maintained a network of open-source projects for decades, on servers that cost around $5 a month.

We don't want to be the next Facebook. The internet used to be great because it connected people all over the world. Today, giant corporate platforms control the flow of information and pit people against each other to farm engagement. We want to promote the old internet: the truly decentralized, grassroots internet, made of many small communities that respect their own privacy and values.

So we build systems that anyone can replicate. Everything here is open source and runs on the cheapest servers available, because a low hosting cost lowers the barrier to running your own websites and communities. If this helps you start yours, it worked.

## What It's For

- Running any number of projects side by side behind one HTTPS proxy, each from its own repository.
- Deploying a project within seconds of a push, through a webhook with its own secret. No build pipeline, container registry, or Kubernetes.
- Running the same way on staging (each project's `main` branch) and production (`release`), and on separate servers for separate groups of projects.
- Optionally accepting web traffic only through Cloudflare, which hides the server's address.

**Status:** server setup, the shared proxy and webhook listener, project configuration, and Cloudflare-only mode work. Deploys, a command for adding projects, shared databases, and backups are next.

## Getting Started

You need a server running Debian 13 (Ubuntu works too) and a hostname for it, such as `stage.example.com`, with a DNS record pointing at the server. Then run:

```bash
curl -fsSL https://raw.githubusercontent.com/wetfish/server/main/setup.sh | sudo bash
```

Setup installs Docker, clones this repository into `/srv/wetfish-server`, asks for the hostname and whether the server is for staging or production, and starts the shared services. When it finishes, `https://<hostname>/` answers `OK`.

To keep the repository somewhere else, clone it there and run `sudo ./setup.sh` from the clone. Setup is safe to re-run, and accepts its answers as options for unattended installs; see `./setup.sh --help`.

## Documentation

- [How it works](docs/how-it-works.md): the shared services, setup, adding projects, and files
- [Cloudflare-only mode](docs/cloudflare.md): accepting web traffic only through Cloudflare
- [Design decisions](docs/design.md): why it is built this way

## License

MIT; see [LICENSE](LICENSE). The Node.js web framework this repository held in 2015–2016 is in the `v0.2.0` tag, under its original GPL-3.0 license.
