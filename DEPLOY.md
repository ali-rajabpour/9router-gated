# Deploying 9Router on Dokploy without public ingress

Three access modes, same stack, same data. Pick one at deploy time by choosing
which compose file Dokploy builds. None publishes 9Router to the internet, none
creates a Traefik route for 9Router, and none touches your other projects on the
VPS. (Headscale mode adds one public service - the Headscale control plane -
but 9Router itself stays private.)

| | Tailscale | SSH tunnel | Headscale |
| --- | --- | --- | --- |
| Compose file | `docker-compose.yml` | `docker-compose.ssh.yml` | `docker-compose.headscale.yml` |
| Client URL | `https://9router.<tailnet>.ts.net` | `http://127.0.0.1:20128` | `http://100.64.0.2:80` |
| Transport | WireGuard + TLS from `tailscale serve` | SSH | WireGuard + HTTP from `tailscale serve` |
| Server-side setup | Tailscale sidecar, ACLs, file mount | Nothing beyond the compose file | Headscale container, sidecar, DNS record |
| Client-side setup | Install Tailscale, log in | Persistent `ssh -L`, one per machine | Install Tailscale, point at Headscale, log in |
| Real TLS certificate | Yes | No, transport is SSH | No, HTTP over WireGuard |
| Extra layer of auth | Tailnet membership | VPS SSH credentials | Mesh membership |
| Works where Tailscale is filtered | No | Yes | Yes (your domain, not `*.tailscale.com`) |
| New public service on VPS | No | No | Yes (Headscale control plane) |

**Default to Tailscale.** It is less to run day to day, it gives you a real
HTTPS URL that every client accepts, and tailnet membership is a genuine
second gate in front of 9Router's own password and API key. Use Headscale when
Tailscale is filtered and you want a mesh rather than per-machine tunnels. Use
SSH when Tailscale is filtered and you want zero extra infrastructure.

## Is Tailscale reachable from your network?

Some countries filter it. Run this from a client machine before committing:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 10 \
  https://controlplane.tailscale.com/health
```

A status code means it works. `Connection reset by peer` means an SNI filter
is killing the TLS handshake, and since the control plane and every DERP relay
live under `*.tailscale.com`, there is no hostname left to reach. Take Path B.

To confirm the filter keys on the hostname rather than something local:

```bash
# same SNI, unrelated destination: still reset => hostname-based filtering
curl -sS -o /dev/null -k --max-time 8 \
  --resolve login.tailscale.com:443:1.1.1.1 https://login.tailscale.com/
# control: any other hostname to the same IP should answer
curl -sS -o /dev/null -k --max-time 8 \
  --resolve example.org:443:1.1.1.1 https://example.org/
```

## Why this shape

All three modes reach 9Router over a loopback hop, and 9Router grants **local**
requests privileged access: keyless `/v1`, password reset, process-spawning
routes. Getting that wrong hands every visitor those privileges, so each mode
has to defeat it differently.

- **Tailscale / Headscale.** `tailscale serve` proxies to
  `127.0.0.1:20128` inside a shared network namespace, but it sets
  `X-Forwarded-For` to the client's mesh address unconditionally
  (`ipn/ipnlocal/serve.go`, `addProxyForwardedHeaders`). 9Router's
  `custom-server.js` strips any client-supplied forwarding headers before
  stamping its own, so the value cannot be spoofed.
- **SSH.** The port is published on the host's loopback interface. Docker's
  userland proxy re-originates the connection, so the container sees the
  bridge gateway address (`172.x`), not `127.0.0.1`. See the caveat in
  section B4, which is why `verify.sh` is not optional.

Headroom stays on the docker bridge in all modes rather than sharing a
namespace with 9Router, so a compromise of that third-party image cannot reach
it over loopback.

---

## 1. Dokploy project

1. **Create → Compose**. Name it `9router`.
2. Point it at this repository.
3. **Compose Path**: `./docker-compose.yml` for Tailscale,
   `./docker-compose.ssh.yml` for SSH, or `./docker-compose.headscale.yml` for
   Headscale. This one field is the mode switch.
4. **Advanced → Isolated Deployments: OFF.** It injects a `networks:` key into
   every service, which is invalid alongside `network_mode` and will fail the
   Tailscale and Headscale deploys.
5. **Do not add a domain to 9Router.** No Traefik router, no `dokploy-network`
   for 9Router. That is the point. (Headscale mode uses `dokploy-network` for
   the Headscale container only, which is the one public service.)

## 2. Environment variables

**Environment tab**. These live in Dokploy, never in a file on the server:

```
JWT_SECRET=<openssl rand -hex 32>
INITIAL_PASSWORD=<a real password>
TS_AUTHKEY=tskey-auth-...        # Tailscale mode only
HEADSCALE_DOMAIN=headscale.example.com  # Headscale mode only
HEADSCALE_USER=9router           # Headscale mode, optional (default: 9router)
HS_AUTHKEY=                      # Headscale mode, optional (auto-generated if empty)
CERT_RESOLVER=                   # Headscale mode, optional. Leave empty if using
                                 # uploaded certs (e.g. Cloudflare Origin).
                                 # Set to "letsencrypt" for ACME.
```

`INITIAL_PASSWORD` is not optional. 9Router falls back to `123456` when it is
unset. It is bootstrap-only: once you set a password in the dashboard, that
bcrypt hash in SQLite takes precedence.

---

# Path A: Tailscale

## A1. Tailnet preparation

In the Tailscale admin console:

1. **DNS → MagicDNS**: enabled.
2. **DNS → HTTPS Certificates**: enabled. Required for `serve` to issue a cert.
3. **Access controls**: define the tag and restrict who may reach it.

   New tailnets ship with a default rule permitting everything
   (`src: ["*"]`, `dst: ["*"]`, `ip: ["*"]`). Replace it. Recent tailnets use
   the `grants` syntax:

   ```jsonc
   {
     "tagOwners": { "tag:nine-router": ["autogroup:admin"] },
     "grants": [
       // Your devices reach the router on the serve port. Nothing else.
       {
         "src": ["autogroup:member"],
         "dst": ["tag:nine-router"],
         "ip":  ["tcp:443"],
       },
     ],
   }
   ```

   Older tailnets use `acls`, where the port belongs on `dst` and there is no
   `ip` field:

   ```jsonc
   {
     "tagOwners": { "tag:nine-router": ["autogroup:admin"] },
     "acls": [
       { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:nine-router:443"] },
     ],
   }
   ```

   Use one style or the other, not both for the same traffic.

   Two mistakes to avoid:

   - **Do not put `tag:nine-router` in `src`.** The router never initiates
     connections to your tailnet, it only receives them. A rule whose `src` and
     `dst` are both the tag grants the node access to itself and grants your
     laptops nothing.
   - **Tagged devices lose their owner's implicit access.** Once the container
     is tagged, the account that authenticated it no longer reaches it by
     default. The rule above is what restores access, so it is required, not
     optional.

   `tcp:443` is deliberate: it is the only port `tailscale serve` listens on,
   and it keeps `:20128` unreachable even though 9Router binds `0.0.0.0` inside
   the namespace.

4. **Settings → Device approval**: on.
5. **Keys → Generate auth key**: reusable, non-ephemeral, tagged `tag:nine-router`.
   Copy it; it is shown once.
6. MFA on the identity provider backing your Tailscale account.

Tagged nodes have key expiry disabled, which is what lets the stack sit
stopped for months and come back without re-authentication.

## A2. File mount for the serve config

**Advanced → Volumes → Add File Mount**. Two fields, both required:

| Field | Value |
| --- | --- |
| **File Path** | `serve.json` |
| **Content** | the contents of `serve.json` from this repository |

File Path is a bare filename. No leading slash, no directory, no `../files/`
prefix. Dokploy writes it to `<project>/files/serve.json`, which is why
`docker-compose.yml` mounts it as `../files/serve.json`.

Confirm the path Dokploy reports after saving. If your version places it
elsewhere, adjust the volume line in `docker-compose.yml` to match.

**Do not mount the repository's `serve.json` directly.** It is committed here
so the configuration is versioned and reviewable, but Dokploy runs `git clone`
into a cleaned directory on every deployment, so a mount like
`./serve.json:/config/serve.json` works once and then breaks. With the
scheduled redeploy job below, that happens on a cron. File Mounts live outside
the cloned directory and survive.

## A3. Deploy

Deploy, then confirm the sidecar actually came up. Dokploy renders every
stderr line as an error and `tailscaled` logs everything to stderr, so read
the state rather than the log colour:

```bash
docker ps --format '{{.Names}}' | grep -i tailscale
docker exec <name> tailscale status         # node active, has an address
docker exec <name> tailscale serve status   # https://... -> http://127.0.0.1:20128
```

### Expected log noise

These appear on every start and are not faults:

| Message | Why |
| --- | --- |
| `tstun: error initializing tun dev stats polling: no such device` | Userspace mode has no TUN device to poll. |
| `magicsock: failed to force-set UDP read/write buffer size ... operation not permitted` | Raising socket buffers needs `NET_ADMIN`, which is deliberately not granted. Affects throughput only. |
| `health(wantrunning-false): Tailscale is stopped.` | Logged before `tailscale up` runs. |
| `health(warming-up): Tailscale is starting.` | Transient. |
| `control: lite map update error ... 409: superseded by another update` | Two control-plane map requests raced at startup. Harmless once; investigate only if it repeats. |
| Headroom printing `Claude Code: ANTHROPIC_BASE_URL=...` | Its usage banner, written to stderr. Means it is up. |

### If nothing routes

- **Device approval.** Section A1 turns it on, so a freshly authenticated node
  sits unapproved and unreachable until you approve it under **Machines**.
  This is the usual cause.
- **No certificate.** `serve` fetches it lazily on the first HTTPS request, so
  a slow first load is normal. If it never issues, **DNS → HTTPS Certificates**
  is off.
- **Connection refused through `serve`.** 9Router is still starting; it boots
  slower than the sidecar.

Your base URL is `https://9router.<your-tailnet>.ts.net`. Skip to
[Verify](#verify).

---

# Path B: SSH tunnel

No tailnet, no sidecar, no file mount. Set **Compose Path** to
`./docker-compose.ssh.yml`, set `JWT_SECRET` and `INITIAL_PASSWORD`, deploy.

## B1. Confirm the bind is loopback-only

The single thing that matters on the server:

```bash
ss -tlnp | grep 20128
```

Expect `127.0.0.1:20128`. If you see `0.0.0.0:20128` or `*:20128`, the
`127.0.0.1:` prefix was dropped from the `ports:` entry and 9Router is exposed
to the internet. Stop and fix that before going further.

## B2. Open the tunnel

From each client machine:

```bash
ssh -N -L 20128:127.0.0.1:20128 <user>@<vps>
```

9Router is then at `http://127.0.0.1:20128` on that machine.

For something that survives sleep, network changes, and reboots, use
`autossh`:

```bash
autossh -M 0 -f -N \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes \
  -L 20128:127.0.0.1:20128 <user>@<vps>
```

`ExitOnForwardFailure=yes` matters. Without it a failed forward leaves you with
a live SSH session and a dead tunnel, which looks like 9Router being down.

**macOS**, `~/Library/LaunchAgents/com.local.9router-tunnel.plist`, then
`launchctl load` it:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.local.9router-tunnel</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/autossh</string>
    <string>-M</string><string>0</string>
    <string>-N</string>
    <string>-o</string><string>ServerAliveInterval=30</string>
    <string>-o</string><string>ServerAliveCountMax=3</string>
    <string>-o</string><string>ExitOnForwardFailure=yes</string>
    <string>-L</string><string>20128:127.0.0.1:20128</string>
    <string>USER@VPS</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
```

**Windows** has OpenSSH built in. Create a Task Scheduler task running at logon:

```
Program:   C:\Windows\System32\OpenSSH\ssh.exe
Arguments: -N -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -L 20128:127.0.0.1:20128 USER@VPS
```

Use key-based auth so nothing prompts. A dedicated key with
`command="",no-pty,no-agent-forwarding,permitopen="127.0.0.1:20128"` in
`authorized_keys` restricts that key to this one forward and nothing else,
which is worth the two minutes.

## B3. Harden the SSH server

The tunnel inherits whatever your SSH configuration already allows, so it is
now part of this system's security. Confirm the basics in `/etc/ssh/sshd_config`:

```
PasswordAuthentication no
PermitRootLogin no
```

## B4. The source-address caveat

Publishing to `127.0.0.1` is safe because Docker's userland proxy re-originates
the connection, so the container sees the bridge gateway address rather than
loopback and 9Router treats the caller as remote. That is the default and it is
what your host almost certainly does.

If `userland-proxy` has been disabled in `/etc/docker/daemon.json`, the DNAT
path can preserve the original source address, and a request arriving from the
host's own loopback could then be seen as local, unlocking keyless `/v1`.

```bash
grep -i userland /etc/docker/daemon.json 2>/dev/null   # expect no output
```

`verify.sh` catches this either way. Run it before you connect any provider.

---

# Path C: Headscale

For networks where `*.tailscale.com` is SNI-filtered. You run your own
Tailscale control plane on your domain, so the filter does not match. The
Tailscale client on your machines points at your Headscale instead of
Tailscale's hosted control plane. 9Router is reachable only from the mesh,
never public.

This is more infrastructure than SSH mode (one extra container + a public
domain), but less per-machine friction (join the mesh once, no tunnel to
maintain). Use it when Tailscale is filtered and you want a mesh VPN.

## C1. DNS and domain

Point a DNS A record at your VPS:

```
headscale.yourdomain.com  A  <vps-ip>
```

Traefik (managed by Dokploy) terminates TLS on this hostname.

## C2. Deploy (fully automated)

Set **Compose Path** to `./docker-compose.headscale.yml`, set `JWT_SECRET`,
`INITIAL_PASSWORD`, and `HEADSCALE_DOMAIN` in the Environment tab. Set
`CERT_RESOLVER` only if you use ACME (e.g. `letsencrypt`). Leave it empty
if you upload custom certificates in Dokploy (e.g. Cloudflare Origin certs).
Leave `HS_AUTHKEY` empty. Deploy.

The Headscale container starts, waits for its own health check, then
automatically:
1. Creates the Headscale user (default `9router`, or the value of
   `HEADSCALE_USER`).
2. Generates a reusable pre-auth key.
3. Writes the key to a shared volume.
4. Prints the key to its container logs.

The Tailscale sidecar waits for the key file, then joins the mesh automatically.
No SSH to the VPS, no manual key generation, no second deploy.

Watch the `headscale-setup` container logs in the Dokploy panel for:

```
========================================
Headscale pre-auth key: hskey-auth-xxxxxxxxx
Use this to join client machines to the mesh:
  tailscale up --login-server=https://headscale.yourdomain.com --auth-key=hskey-auth-xxxxxxxxx --accept-dns=false
========================================
```

The key is printed on every deploy, not just the first. If you lose it,
redeploy and check the `headscale-setup` container logs.

Confirm Headscale is reachable (optional, from any machine):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://headscale.yourdomain.com/health
# expect 200
```

## C3. Find the sidecar's mesh IP

The mesh IP is your base URL. Two ways to find it, neither requires SSH:

**From the Dokploy panel:** check the `sidecar` container logs for a line like
`tailscale up: setting hostname to "9router"; ... 100.64.0.2`.

**From a client machine (after C5):** run `tailscale status` and look for the
`9router` node.

## C4. Enroll client machines

On each client, install the Tailscale client and join your Headscale:

```bash
tailscale up --login-server https://headscale.yourdomain.com --accept-dns=false
```

Approve the node in Headscale if you enabled node approval:

```bash
docker exec <name> headscale nodes list
docker exec <name> headscale nodes approve --node <id>
```

## C5. The HTTPS gap

Headscale does not support per-node TLS certificate provisioning
(`tailscale cert` / HTTPS serve). So `tailscale serve` runs in **HTTP mode**
on port 80, and `AUTH_COOKIE_SECURE` is `false`. WireGuard encrypts the
transport between mesh nodes, so the traffic is encrypted in transit - but
clients that require an `https://` base URL will not work without a local
TLS terminator. For CLI tools (Claude Code, Hermes, curl) this is fine; they
accept `http://` URLs. For browsers, the dashboard works over HTTP on the
mesh.

If you need HTTPS on the client side, run a local reverse proxy (Caddy, nginx)
on the client machine that terminates TLS and forwards to the mesh IP.

## C6. DERP and censorship resistance

The embedded DERP relay relays traffic between mesh nodes over HTTPS when
direct WireGuard UDP cannot connect. Since Headscale and 9Router are on the
same VPS, the relay hop adds ~zero latency. STUN (UDP 3478) is configured but
its port is not published, so it is unreachable - clients skip direct-path
discovery and relay through DERP over HTTPS/443. Pure HTTPS, no UDP, same
transport as cloudflared. If your network filters `*.tailscale.com` but allows
other HTTPS, this works.

---

# Verify

From a client machine, against your mode's base URL:

```bash
./verify.sh https://9router.<your-tailnet>.ts.net   # Tailscale
./verify.sh http://127.0.0.1:20128                  # SSH, tunnel up
./verify.sh http://100.64.0.2:80                    # Headscale, mesh IP
```

Expected: `/v1/models` → 401, `/api/mcp/` → 403, `/api/settings` → 401,
`/dashboard` → 307. A bare hostname is accepted and assumed to be HTTPS.
`./verify.sh --self-test` checks the script itself without contacting a server.

**A 200 on the first check means the loopback hop leaked local privileges.**
Anyone who can reach 9Router can then spend your provider subscriptions and
read the tokens. Stop and fix it before connecting anything.

On the VPS:

```bash
ss -tlnp | grep -E '20128|8787'
# Tailscale mode:  no output.
# SSH mode:       127.0.0.1:20128 only.
# Headscale mode: no output (9router in sidecar netns).
```

# First login and clients

1. Open your base URL, log in with `INITIAL_PASSWORD`, change the password
   immediately.
2. Connect providers. Dashboard → Providers.
3. Dashboard → generate an API key.
4. Enable Headroom: Endpoint → Token Saver → Headroom. The URL should already
   read `http://headroom:8787`; recheck status, then enable.

Point clients at `<base-url>/v1` with that API key. Claude Code:

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:20128     # or the ts.net / mesh IP URL
export ANTHROPIC_AUTH_TOKEN=<9router key>
```

Hermes, via `hermes model` → **Custom endpoint**, or directly:

```yaml
# ~/.hermes/config.yaml
providers:
  9router:
    api: http://127.0.0.1:20128/v1
    key_env: NINEROUTER_API_KEY
    transport: chat_completions

model:
  default: <model id from the 9Router dashboard>
  provider: custom:9router
```

```bash
# ~/.hermes/.env
NINEROUTER_API_KEY=<9router key>
```

Hermes Desktop needs `v2026.6.19` or newer; earlier builds had no API key
field on the custom endpoint form. The CLI has always supported it, and both
read the same `~/.hermes/config.yaml`.

Note that Cursor routes some requests through its own backend, which cannot
reach a private endpoint. That is a Cursor limitation and applies to both
modes.

# Auto-update

You cannot webhook this. Docker Hub webhooks are configured by the repository
owner, and `decolua/9router` is not yours, so there is no push event to
subscribe to. Watchtower would work but requires mounting the Docker socket,
which is root-equivalent on a host running your other projects. Not worth it.

Polling instead. **Dokploy → Schedule Jobs → Create**:

- Schedule: `0 */6 * * *` (adjust to taste)
- Command:

  ```bash
  curl -fsS -X POST 'https://<your-dokploy-panel>/api/compose.deploy' \
    -H 'x-api-key: <dokploy-api-key>' \
    -H 'Content-Type: application/json' \
    -d '{"composeId":"<composeId from the project URL>"}'
  ```

`pull_policy: always` in both compose files makes the re-pull explicit rather
than incidental. Confirm the exact endpoint name against your panel's
`/swagger`. It has been `compose.deploy` in recent versions.

**Understand what you turned on.** Tracking `:latest` with an unattended
redeploy means an upstream compromise reaches your provider OAuth tokens
without review. If that stops being acceptable, pin a version tag and drop
the scheduled job.

# Stopping and restarting

Dokploy Stop halts the containers; volumes persist.

| Volume | Contents |
|---|---|
| `9router-data` | `db/data.sqlite`, provider OAuth tokens, API keys, `jwt-secret`, certs, backups |
| `tailscale-state` | Tailscale/Headscale modes: node identity, serve config, TLS certificate (Tailscale mode only) |
| `headscale-data` | Headscale mode only: control plane database, noise private key, DERP private key |

Start returns the same configuration, and in Tailscale mode the same hostname
and certificate. The auth key is consumed only on first run. In Headscale mode,
the Headscale database and keys persist, so the control plane survives
restarts without re-initialization.

Do not delete these volumes. `9router-data` is your entire configuration; if
`JWT_SECRET` were ever unset, it would also hold the auto-generated secret.

# Switching modes later

Change **Compose Path** and redeploy. All three files declare a `9router-data`
volume with the same name, so within one Dokploy project your database,
provider connections, and API keys carry across. Set `TS_AUTHKEY` for Tailscale
mode, or `HEADSCALE_DOMAIN` for Headscale mode (the pre-auth key is
auto-generated). Run `verify.sh` again against the new base URL.

# Notes

- Tailscale mode also exposes the dashboard at `http://<tailnet-ip>:20128`,
  bypassing `serve`. Still safe, since the peer address is non-loopback and so
  carries no local privileges, but the ACL in A1 restricts the tailnet to
  `:443` anyway. Headscale mode has the same property at `http://<mesh-ip>:20128`.
- Headsscale mode: the Headscale control plane is the one public service in
  the stack. Harden it: keep the VPS SSH key-only, run Fail2Ban/CrowdSec, and
  restrict access to the Headscale API if possible. The control plane does not
  hold 9Router secrets, but a compromise lets an attacker enroll rogue nodes.
- `REQUIRE_API_KEY` appears in upstream's `.env.example` and is dead code: no
  references anywhere in `src/`. API-key enforcement on `/v1` for remote
  callers is unconditional. Do not rely on that variable.
- `NEXT_PUBLIC_*` variables are baked in at image build time and cannot be
  overridden at runtime in a prebuilt image. Left at defaults.
- Design rationale and the rejected alternatives are in [docs/DESIGN.md](docs/DESIGN.md).
