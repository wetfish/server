# Cloudflare-Only Mode

Optional. With it on, ports 80 and 443 accept connections only from [Cloudflare's proxies](https://www.cloudflare.com/ips/) and any addresses you [allow for testing](#testing-without-cloudflare), so the sites cannot be reached by the server's IP address and scans of it find nothing. Caddy takes each visitor's real address from the `CF-Connecting-IP` header Cloudflare sends. SSH and every other port are untouched.

## Before Turning It On

The mode covers the whole server: any domain on it that is not proxied becomes unreachable, including to Let's Encrypt.

1. **Proxy every domain on the server,** including the server's own hostname, which GitHub's webhooks use. Each DNS record pointing at the server must be **Proxied** (orange cloud).
2. **Set SSL/TLS encryption to Full (strict).** With Flexible, Cloudflare connects over plain HTTP and Caddy's redirect to HTTPS loops forever.
3. **Turn off Always Use HTTPS.** Caddy redirects to HTTPS itself, and Let's Encrypt must reach it over plain HTTP to issue certificates.
4. **Keep subdomains one level deep,** such as `stage-wiki.example.com` rather than `wiki.stage.example.com`. Cloudflare's free certificate covers `*.example.com` only.

The SSL/TLS settings apply to the whole Cloudflare zone, so check what they mean for any other sites in it.

## Commands

```bash
./cloudflare.sh enable     # turn it on, or re-apply it
./cloudflare.sh status     # show whether it is on, when the ranges were downloaded, and the allowlist
./cloudflare.sh update     # download Cloudflare's address ranges again now
./cloudflare.sh disable    # turn it off
```

`setup.sh` can turn it on too. `enable` installs `nftables` and `curl` if they are missing. Run `disable` before changing a domain back to DNS only.

## Testing Without Cloudflare

**An SSH tunnel** needs no changes on the server. The firewall never filters the server's own connections, so a tunnel to its port 443 reaches Caddy. Connect to the server's real address, since a proxied hostname resolves to Cloudflare:

```bash
ssh -L 8443:localhost:443 <server-address>
curl --resolve stage-wiki.example.com:8443:127.0.0.1 https://stage-wiki.example.com:8443/
```

**The allowlist** lets an address or range reach ports 80 and 443 directly:

```bash
./cloudflare.sh allowlist add 203.0.113.7       # IPv4 or IPv6, an address or a range
./cloudflare.sh allowlist remove 203.0.113.7
./cloudflare.sh allowlist                       # show the list
```

`remove` only takes an address off the allowlist; it never blocks anything. Addresses that are neither Cloudflare's nor on the allowlist are blocked. Allowed addresses are not trusted to send `CF-Connecting-IP`, so Caddy logs them as themselves. The allowlist survives updates and reboots, and `disable` clears it.

Either way, point the domain at the server for the test with `curl --resolve` or a line in your hosts file. Caddy's certificate is valid for the domain, so browsers show no warnings.

## How It Works

- **Firewall:** `cloudflare/firewall.nft`, with Cloudflare's ranges and the allowlist filled in, is installed as `/etc/cloudflare-only.nft` and loaded at boot, before Docker starts, by `cloudflare-firewall.service`. Its rules live in their own nftables table (`cloudflare_only`), so they never change Docker's rules or any other firewall. They drop connections to ports 80 and 443 from everyone else, both those Docker forwards to Caddy and those to the server itself.
- **Real visitor addresses:** `cloudflare/trusted-proxies.Caddyfile`, with the same ranges filled in, becomes `generated/caddy/global/cloudflare.Caddyfile`, telling Caddy to trust `CF-Connecting-IP` from Cloudflare. Private network ranges are trusted too, because Docker hands Caddy IPv6 connections through its userland proxy, from the Docker network; the firewall ensures those also come from Cloudflare.
- **Keeping the ranges current:** `cloudflare-update.timer` downloads Cloudflare's lists weekly and applies any change in one step. A failed or malformed download keeps the current ranges, and Caddy settings it rejects are put back, so an update cannot lock out Cloudflare or break Caddy. See its runs with `journalctl -u cloudflare-update`.

Restarting Debian's `nftables.service` flushes every firewall rule on the server, including these and Docker's. If that happens, run `systemctl restart cloudflare-firewall docker`.
