# Deploying 9Router on Dokploy without public ingress

Three access modes, same stack, same data. Pick one at deploy time by choosing
which compose file Dokploy builds. None publishes 9Router to the internet, none
creates a Traefik route for 9Router, and none touches your other projects on the
VPS. (Headscale mode joins your own Headscale control plane, a central hub that
serves all your private apps; this stack runs no control plane of its own.)

| | Tailscale | SSH tunnel | Headscale |
| --- | --- | --- | --- |
| Compose file | `docker-compose.yml` | `docker-compose.ssh.yml` | `docker-compose.headscale.yml` |
| Client URL | `https://9router.<tailnet>.ts.net` | `http://127.0.0.1:20128` | `http://9router.mesh.internal` |
| Transport | WireGuard + TLS from `tailscale serve` | SSH | HTTP inside WireGuard, relayed over HTTPS/443 |
| Server-side setup | Tailscale sidecar, ACLs, file mount | Nothing beyond the compose file | Sidecar plus a one-time pre-auth key |
| Client-side setup | Install Tailscale, log in | Persistent `ssh -L`, one per machine | Install Tailscale, join the mesh (once for all apps) |
| Real TLS certificate | Yes | No, transport is SSH | No, HTTP over WireGuard |
| Extra layer of auth | Tailnet membership | VPS SSH credentials | Mesh membership + control-plane policy |
| Works where Tailscale is filtered | No | Yes | Yes (your control-plane domain, not `*.tailscale.com`) |
| New public service on VPS | No | No | No (the control plane is elsewhere) |

**Default to Tailscale.** It is less to run day to day, it gives you a real
HTTPS URL that every client accepts, and tailnet membership is a genuine
second gate in front of 9Router's own password and API key. Use Headscale when
Tailscale is filtered and you want a mesh rather than per-machine tunnels, and
you already run a Headscale control plane. Use SSH when Tailscale is filtered and you want zero extra infrastructure.

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

- **Tailscale.** `tailscale serve` proxies to `127.0.0.1:20128` inside a
  shared network namespace, but it sets `X-Forwarded-For` to the client's mesh
  address unconditionally (`ipn/ipnlocal/serve.go`,
  `addProxyForwardedHeaders`). 9Router's `custom-server.js` strips any
  client-supplied forwarding headers before stamping its own, so the value
  cannot be spoofed.
- **Headscale.** 9Router is not in the sidecar's namespace at all. The
  sidecar forwards to `9router:20128` over the stack's private Docker bridge,
  so 9Router sees the sidecar's bridge address, a non-loopback peer. See C5.
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
   in any mode. That is the point.

## 2. Environment variables

**Environment tab**. These live in Dokploy, never in a file on the server:

```
JWT_SECRET=<openssl rand -hex 32>
INITIAL_PASSWORD=<a real password>
TS_AUTHKEY=tskey-auth-...        # Tailscale mode (Headscale mode: hskey-auth-..., see below)
HUB_DOMAIN=hub.example.com       # Headscale mode only, the control plane's public name
                                 # Headscale mode also sets TS_AUTHKEY, but to a
                                 # single-use hskey-auth-... key, see C1
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

# Path C: Headscale (join your own control plane)

For networks where `*.tailscale.com` is SNI-filtered. You run your own
Headscale control plane on your own domain, once, as a central hub for all your
private apps, and this stack only joins it. Control traffic and the DERP relays
ride HTTPS on 443 through Cloudflare, so nothing is opened on this server.
9Router is reachable only from the mesh, never public, and this stack has no
public service at all.

Deploying the control plane, enrolling devices, deleting nodes, the access
policy, relays, backups and upgrades happen there, not here. It must provide:

- a login server URL, the public name `HUB_DOMAIN`
- a single-use pre-auth key tagged `tag:nine-router`
- a policy granting the owner's devices `tag:nine-router` on `tcp/80`

Identity comes from that policy:

| Who | Allowed |
| --- | --- |
| Devices of user `owner` (Mac, phone) | `tag:nine-router` on `tcp/80`; ping between devices |
| `tag:nine-router` (the sidecar in front of 9Router) | nothing outbound |

A stolen laptop cannot reach your other machines through the mesh, and port
`20128` on the mesh address is unreachable because only `tcp/80` is granted.

## C1. Mint the sidecar key

The key is single use and valid one hour. Request it right before C2: on your
Headscale control plane, create a pre-auth key tagged `tag:nine-router` (it starts
with `hskey-auth-`).

## C2. Deploy

Set **Compose Path** to `./docker-compose.headscale.yml` and these in the
Environment tab:

```
JWT_SECRET=<openssl rand -hex 32>
INITIAL_PASSWORD=<a real password>
HUB_DOMAIN=hub.example.com
TS_AUTHKEY=<hskey-auth-... from C1>
```

The deploy refuses to start if any of them is missing or empty. The sidecar
registers with `https://<HUB_DOMAIN>` as `9router`, tagged by the key. The
control plane's node list shows `9router` online with `tag:nine-router`.

`TS_AUTHKEY` is consumed on first start only (`TS_AUTH_ONCE` plus the
`hub-state` volume). **Keep the spent value in the variable**: the compose file
fails the deploy when it is empty, so a forgotten variable fails loudly
instead of starting a sidecar that cannot register.

## C3. Verify from the Mac

On the Headscale account:

```bash
tailscale status                              # 9router listed
nc -vz 9router.mesh.internal 80               # succeeds
nc -vz -w 5 9router.mesh.internal 20128       # must fail
./verify.sh http://9router.mesh.internal      # 401, 403, 401, 307
```

Your base URL is `http://9router.mesh.internal` (port 80).

## C4. Replacing the sidecar identity

If `hub-state` is lost, the old `9router` node is orphaned and its name is
taken. Delete the stale node on the control plane, mint a new key (C1), put it
in `TS_AUTHKEY` and redeploy.

## C5. Why the sidecar forwards over the bridge

`tailscale serve` in HTTP mode matches requests on the node's DNS name, which
Headscale does not provide here, so the sidecar uses a raw TCP forward
instead. A raw forward adds no `X-Forwarded-For`, and 9Router
treats a connection from `127.0.0.1` without that header as **local**: keyless
`/v1`, password reset, and the process-spawning routes.

So 9Router runs in its own container, not in the sidecar's network namespace,
and the sidecar forwards to `9router:20128` over the stack's private bridge.
Every mesh request arrives from the sidecar's bridge address, an ordinary
remote client. Nothing is published on the host. The sidecar's mesh name
(`TS_HOSTNAME=9router`) is set through the environment, not the compose
`hostname:` key: a container hostname of `9router` would put "9router -> this container" in `/etc/hosts` and the
forward would dial itself.

## C6. The HTTPS gap

Headscale cannot issue per-node certificates, so 9Router is served as plain
HTTP inside WireGuard and `AUTH_COOKIE_SECURE` is `false`. On the wire it is
still HTTPS to Cloudflare wrapping WireGuard wrapping HTTP. CLI tools accept
`http://` base URLs. If an IDE insists on `https://`, run a local terminator on
that machine:

```bash
caddy reverse-proxy --from localhost:8443 --to http://9router.mesh.internal --internal-certs
```

## C7. DERP relay

UDP 3478 (STUN) is neither published nor used by the control plane, so clients relay
through its DERP regions (or a relay on this server, if you added one) over
HTTPS/443 rather than attempting direct WireGuard. A relay next to 9Router keeps
the extra hop cheap; adding one is a control-plane operation.

---

# Verify

From a client machine, against your mode's base URL:

```bash
./verify.sh https://9router.<your-tailnet>.ts.net   # Tailscale
./verify.sh http://127.0.0.1:20128                  # SSH, tunnel up
./verify.sh http://9router.mesh.internal            # Headscale, from a mesh device
```

Expected: `/v1/models` → 401, `/api/mcp/probe` → 403, `/api/settings` → 401,
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
# Headscale mode: no output (nothing published, nothing public in this stack).
```

# First login and clients

1. Open your base URL, log in with `INITIAL_PASSWORD`, change the password
   immediately.
2. Connect providers. Dashboard → Providers.
3. Dashboard → generate an API key.
4. Enable Headroom: Endpoint → Token Saver → Headroom. The URL should already
   read `http://headroom:8787`; recheck status, then enable. Raise the Headroom timeout there to 20000 ms: the 3000 ms default times out on large agent requests, and a timed-out request is sent uncompressed.

Point clients at `<base-url>/v1` with that API key. Claude Code:

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:20128     # or the ts.net / mesh name URL
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
reach a private endpoint. That is a Cursor limitation and applies to all
three modes.

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

`pull_policy: always` in the Tailscale and SSH compose files makes the re-pull
explicit rather than incidental. The Headscale compose file pins every image
instead, so there you update by bumping `NINEROUTER_IMAGE` and redeploying. Confirm the exact endpoint name against your panel's
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
| `tailscale-state` | Tailscale mode: node identity, serve config, TLS certificate |
| `hub-state` | Headscale mode: the sidecar's identity on the control plane |

Start returns the same configuration, and in Tailscale mode the same hostname
and certificate. The auth key is consumed only on first run. In Headscale mode
the sidecar keeps its identity in `hub-state`, so restarts need no new
key; the control plane's own database and keys are backed up there.

Do not delete these volumes. `9router-data` is your entire configuration; if
`JWT_SECRET` were ever unset, it would also hold the auto-generated secret.

# Switching modes later

Change **Compose Path** and redeploy. All three files declare a `9router-data`
volume with the same name, so within one Dokploy project your database,
provider connections, and API keys carry across. Set `TS_AUTHKEY` (`tskey-auth-`)
for Tailscale mode, or `HUB_DOMAIN` and a single-use `TS_AUTHKEY`
(`hskey-auth-`) for Headscale mode. Run `verify.sh` again against the new base
URL.

# Notes

- Tailscale mode also exposes the dashboard at `http://<tailnet-ip>:20128`,
  bypassing `serve`. Still safe, since the peer address is non-loopback and so
  carries no local privileges, but the ACL in A1 restricts the tailnet to
  `:443` anyway. In Headscale mode the policy allows only `tcp/80`, so
  `:20128` on the mesh address is unreachable.
- Headscale mode: nothing in this stack is public, and it holds no
  control-plane secrets: the sidecar carries only its own node identity
  (`hub-state`). The control plane is the high-value target; keep its
  one-shot key flags reset and keep the VPS SSH key-only.
- `REQUIRE_API_KEY` appears in upstream's `.env.example` and is dead code: no
  references anywhere in `src/`. API-key enforcement on `/v1` for remote
  callers is unconditional. Do not rely on that variable.
- `NEXT_PUBLIC_*` variables are baked in at image build time and cannot be
  overridden at runtime in a prebuilt image. Left at defaults.
- Design rationale and the rejected alternatives are in [docs/DESIGN.md](docs/DESIGN.md).
