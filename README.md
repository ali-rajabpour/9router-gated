# dokploy-9router-private

A hardened [9Router](https://github.com/decolua/9router) deployment for
[Dokploy](https://dokploy.com), reachable only by you. Three access modes —
[Tailscale](https://tailscale.com), an SSH tunnel, or a self-hosted
[Headscale](https://headscale.net) mesh — sharing one stack and one database.

No public DNS record. No Traefik route for 9Router. Nothing about 9Router is
exposed to the internet. (Headscale mode adds one public service — the
Headscale control plane itself — but 9Router stays private.) Nothing about
the rest of your server changes.

---

## Why this exists

I run a self-hosted VPS with Dokploy, hosting a number of unrelated production
projects. I wanted 9Router on it: an AI router that fronts Claude Code,
Cursor, Copilot, and friends, giving them fallback across providers and
compressing tool output to save tokens.

Four problems got in the way.

**1. The upstream compose file does not work on Dokploy.** Dokploy routes
traffic through Traefik, which needs Docker labels and a shared network on
every service it serves. The official `docker-compose.yml` has neither, and
it sets `container_name`, which Dokploy's own documentation warns breaks logs
and metrics.

**2. I could not convince myself it was safe to expose.** This is the part
that changed the design. 9Router's SQLite database holds live OAuth tokens for
every provider you connect. Losing it means someone else spending your Claude
and Copilot subscriptions, and walking away with the tokens.

I read the upstream authorization model rather than trusting the README, and
it is genuinely well built: deny-by-default on `/api/*`, JWT on the dashboard,
progressive login lockout, and a set of process-spawning routes restricted to
local callers with client-supplied forwarding headers stripped so they cannot
be spoofed.

But one thing does not go away. The `/v1` endpoint has to stay reachable by
IDEs and CLI tools that speak plain HTTP with a bearer token. No identity proxy
can gate that path without breaking every client. Cloudflare Access, Zero
Trust, an OAuth proxy; all of them end up with a bypass rule on `/v1`, and
you are back to a single API key standing between the public internet and your
provider tokens. Cloudflare Tunnel has a second problem for this workload:
TLS terminates at their edge, so every prompt, every file your agent reads, and
every token passes through their infrastructure in plaintext.

The honest fix is not to expose it at all.

**3. I wanted upstream updates without babysitting.** The usual answer,
Watchtower, wants the Docker socket mounted. On a box running everything else
I own, that is root-equivalent access traded for update convenience. No.

**4. I stop this service when I am not using it.** Restarting had to bring
back the same configuration, the same provider logins, and the same hostname,
not a fresh install asking me to reconnect eleven providers.

Then a fifth problem showed up after the first version shipped: **Tailscale is
filtered where I live.** Not throttled, not slow. The TLS handshake gets an
injected RST the moment the ClientHello carries an SNI under `tailscale.com`,
and since both the control plane and every DERP relay live there, the client
has nowhere to connect. That is what the second and third access modes are for.

## What this repository does about it

Three ways in. Same 9router container, same volumes, same security properties.
You pick one by choosing which compose file Dokploy builds.

**Tailscale.** 9Router runs inside a Tailscale sidecar's network namespace.
`tailscale serve` terminates TLS and forwards to it over loopback. Reachable at
`https://9router.<your-tailnet>.ts.net` from your own devices and nowhere else.

```
tailnet ──TLS 443──> [tailscale sidecar] ──127.0.0.1:20128──> [9router]
                            │  (shared netns)                     │
                            └── docker bridge ────────────> [headroom :8787]
```

**SSH tunnel.** No sidecar. The port binds to the VPS's loopback interface, and
you reach it through `ssh -L` from a machine that already has shell access.
Reachable at `http://127.0.0.1:20128` on that machine.

```
client ──SSH──> [vps 127.0.0.1:20128] ──docker bridge──> [9router] ──> [headroom :8787]
```

**Headscale.** A self-hosted Tailscale control plane on your own domain, for
networks where `*.tailscale.com` is SNI-filtered. Headscale + embedded DERP
relay run as a container exposed via Traefik on `headscale.yourdomain.com`. A
Tailscale sidecar joins your Headscale tailnet (not Tailscale's) and runs
`tailscale serve` in HTTP mode. Reachable at `http://100.64.0.2:80` from your
mesh devices.

```
mesh ──HTTP 80──> [tailscale sidecar] ──127.0.0.1:20128──> [9router]
                       │  (shared netns)                     │
                       └── docker bridge ────────────> [headroom :8787]

headscale.yourdomain.com ──HTTPS 443──> [headscale container]  (control + DERP)
```

Common to all three:

- **Your host's networking is untouched.** In Tailscale mode `tailscale0`
  exists only inside the container namespace: no root daemon, no rewritten
  `/etc/resolv.conf`, no new firewall chains, nothing left behind if you delete
  the stack. The sidecar runs in userspace mode, so it needs neither
  `NET_ADMIN` nor `/dev/net/tun`. In SSH mode there is no VPN at all.
- **Traefik is not involved.** The label problem disappears rather than
  getting solved.
- **Two layers on every request.** Tailnet membership or SSH credentials,
  then 9Router's own password and API key.
- **Updates poll instead of listening.** A Dokploy scheduled job calls
  Dokploy's own API to redeploy. No Docker socket exposed.
- **State survives.** Named volumes keep the database, provider tokens, node
  identity, and TLS certificate across stop/start cycles, and across a switch
  between the two modes.

### The subtle part

Proxying over loopback is exactly the thing that could have broken this.
9Router grants *local* requests elevated access: `/v1` without an API key,
plus password reset and the process-spawning routes. A naive loopback hop
would hand every visitor those privileges.

In Tailscale and Headscale modes it holds because `tailscale serve` sets
`X-Forwarded-For` to the client's mesh address unconditionally
(`ipn/ipnlocal/serve.go`, `addProxyForwardedHeaders`), and 9Router's
`custom-server.js` strips any client-supplied forwarding headers before
stamping its own. Remote callers stay remote:

```
client 100.x → serve (TLS :443 or HTTP :80) → XFF=100.x, X-Forwarded-Proto=…
  → 127.0.0.1:20128 → strips spoofed headers, stamps x-9r-via-proxy=1
  → isLocalRequest() = false
```

In SSH mode it holds because Docker's userland proxy re-originates the
published connection, so the container sees the bridge gateway address rather
than loopback.

`verify.sh` asserts this after every deploy, in both modes. If those checks
ever fail, the central assumption has broken and you should stop before
connecting providers.

Headroom deliberately stays on the Docker bridge rather than in the shared
namespace. Inside it, that third-party image could reach 9Router over loopback
with no forwarding header and inherit local privileges. On the bridge it is
treated as the remote client it is.

## Which mode should I use?

Default to Tailscale. It is less to run, it gives you a real HTTPS URL that
every client accepts, and tailnet membership is a genuine second gate.

Use Headscale if Tailscale is filtered on your network and you want a mesh
VPN rather than per-machine SSH tunnels. You run a control plane + DERP relay
on your own domain, so SNI filters on `*.tailscale.com` miss it. More
infrastructure than SSH, but less per-machine friction: join the mesh once,
every CLI and IDE on that machine reaches 9Router with no tunnel to maintain.

Use SSH if Tailscale cannot connect from your network and you would rather not
add a mesh VPN at all. Check first:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 10 \
  https://controlplane.tailscale.com/health
```

A status code means Tailscale works. `Connection reset by peer` means an SNI
filter is killing the handshake, and no amount of configuration gets around
it. Take the SSH path.

The trade-off is honest in all directions. Tailscale gives you a real
certificate and a stable hostname; Headscale gives you a mesh that survives
SNI filtering at the cost of running a control plane and no per-node TLS
certificate (HTTP over WireGuard, not HTTPS); SSH gives you zero extra
infrastructure and survives filtering, at the cost of a tunnel to keep alive
on each machine and no TLS for clients that insist on it.

## Contents

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | Tailscale mode: sidecar, 9Router, Headroom |
| `docker-compose.ssh.yml` | SSH mode: 9Router bound to host loopback, Headroom |
| `docker-compose.headscale.yml` | Headscale mode: Headscale + sidecar, 9Router, Headroom |
| `serve.json` | `tailscale serve` config (Tailscale mode), mounted via Dokploy |
| `serve-headscale.json` | `tailscale serve` config (Headscale mode, HTTP), mounted via Dokploy |
| `headscale-config.yaml` | Headscale server config, mounted via Dokploy |
| `.env.example` | The required secrets |
| `verify.sh` | Post-deploy assertions that privileges did not leak |
| `DEPLOY.md` | Full runbook for all three modes |
| `docs/DESIGN.md` | Design rationale, upstream review, rejected alternatives |

## Quick start

Create a Dokploy **Compose** project from this repository, set **Compose Path**
to your mode's file, leave **Isolated Deployments off**, add no domain, and set
`JWT_SECRET` and `INITIAL_PASSWORD` in the Environment tab.

**Tailscale mode**, `./docker-compose.yml`:

1. In the Tailscale admin console, enable MagicDNS and HTTPS Certificates, then
   replace the default allow-everything policy with:

   ```jsonc
   {
     "tagOwners": { "tag:nine-router": ["autogroup:admin"] },
     "grants": [
       {
         "src": ["autogroup:member"],
         "dst": ["tag:nine-router"],
         "ip":  ["tcp:443"],
       },
     ],
   }
   ```

   The tag goes in `dst` only. Putting it in `src` as well grants the node
   access to itself and your own machines nothing. On older tailnets that use
   `acls` instead of `grants`, see [DEPLOY.md](DEPLOY.md) for the equivalent.

2. Generate a reusable, non-ephemeral auth key carrying `tag:nine-router`, and
   set it as `TS_AUTHKEY`.
3. Add a Dokploy File Mount with **File Path** `serve.json` and the contents of
   `serve.json` as its content. Mount the file this way rather than from the
   repository, which Dokploy re-clones on every deploy.
4. Deploy, then `./verify.sh https://9router.<your-tailnet>.ts.net`.

**SSH mode**, `./docker-compose.ssh.yml`:

1. Deploy. There is no step 2 on the server.
2. On the VPS, confirm `ss -tlnp | grep 20128` shows `127.0.0.1:20128` and not
   `0.0.0.0:20128`.
3. On each client, `ssh -N -L 20128:127.0.0.1:20128 <user>@<vps>`, or the
   `autossh` service in [DEPLOY.md](DEPLOY.md) for something that survives
   sleep and reboots.
4. `./verify.sh http://127.0.0.1:20128`.

**Headscale mode**, `./docker-compose.headscale.yml`:

1. Point a DNS record at your VPS for `headscale.yourdomain.com`.
2. Edit `headscale-config.yaml` line 5 — replace `HEADSCALE_DOMAIN` with your
   actual domain. Headscale reads this file literally; no env substitution.
3. Add three Dokploy File Mounts: `serve-headscale.json`,
   `headscale-config.yaml` (same pattern as `serve.json` in Tailscale mode).
4. Set `HEADSCALE_DOMAIN` and `HS_AUTHKEY` in the Environment tab. Generate the
   Headscale pre-auth key after first deploy:
   `docker exec <headscale-container> headscale users create <user>` then
   `headscale preauthkeys create --user <user>`.
5. Deploy Headscale first, then enroll the sidecar. Full steps in
   [DEPLOY.md](DEPLOY.md) §C.
6. On each client, install Tailscale and join your Headscale:
   `tailscale up --login-server https://headscale.yourdomain.com`.
7. `./verify.sh http://100.64.0.2:80` (replace with your sidecar's mesh IP).

Full instructions, including client configuration for Claude Code and Hermes,
the update job, and how to switch modes later, are in [DEPLOY.md](DEPLOY.md).

> `INITIAL_PASSWORD` is not optional. 9Router falls back to `123456` when it is
> unset.

## Requirements

- A VPS running Dokploy
- **Tailscale mode**: a Tailscale account (the free tier is sufficient) and the
  client installed on each machine. Windows, macOS, Linux, iOS, and Android all
  have first-class clients
- **SSH mode**: SSH access to the VPS, and `autossh` if you want the tunnel to
  stay up unattended
- **Headscale mode**: a domain name for the Headscale control plane (Traefik
  provides TLS), and the Tailscale client on each machine pointed at your
  Headscale server instead of Tailscale's hosted control plane

## Trade-offs

In Tailscale mode, every device that uses 9Router must be on your tailnet. For
a single-operator setup that is a small cost, but if you need access from a
machine where you cannot install Tailscale, use SSH mode instead.

In Headscale mode, you run and maintain a control plane + DERP relay. It is
lightweight, but it is another public-facing service and another thing to keep
up. If Headscale goes down, new nodes cannot join and relayed connections drop
(already-enrolled nodes with direct WireGuard connectivity survive). You also
get no per-node TLS certificate — `tailscale serve` runs in HTTP mode, so
`AUTH_COOKIE_SECURE` is `false`. WireGuard encrypts the transport, but clients
that insist on an `https://` base URL will not work without a local terminator.
Use this mode only when Tailscale's hosted control plane is filtered.

In SSH mode, the tunnel is a moving part. If it drops, clients get connection
refused rather than a graceful error. There is also no TLS for clients that
require an `https://` base URL, and the security boundary becomes your SSH
configuration, so key-only authentication is not optional.

Tracking `:latest` with an unattended redeploy means an upstream compromise
reaches your provider tokens without review. Pin a version tag and drop the
scheduled job if that trade is not one you want.

## Acknowledgements

- [9Router](https://github.com/decolua/9router) by decolua
- [Headroom](https://github.com/chopratejas/headroom) by chopratejas
- [Dokploy](https://dokploy.com) and [Tailscale](https://tailscale.com)

This project is not affiliated with or endorsed by any of them.

## Author

**Ali Rajabpour Sanati**
[Rajabpour.com](https://Rajabpour.com)

## License

[MIT](LICENSE) © Ali Rajabpour Sanati
