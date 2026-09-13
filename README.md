# 9router-gated

A hardened [9Router](https://github.com/decolua/9router) deployment for
[Dokploy](https://dokploy.com), reachable only by you. Three access modes -
[Tailscale](https://tailscale.com), an SSH tunnel, or a self-hosted
[Headscale](https://headscale.net) mesh - sharing one stack and one database.

No public DNS record. No Traefik route for 9Router. Nothing about 9Router is
exposed to the internet. (Headscale mode adds one public service - the
Headscale control plane itself - but 9Router stays private.) Nothing about
the rest of your server changes.

---

## Table of contents

- [Why this exists](#why-this-exists)
- [What this repository does about it](#what-this-repository-does-about-it)
- [Which mode should I use?](#which-mode-should-i-use)
- [Prerequisites](#prerequisites)
- [Installation: Tailscale mode](#installation-tailscale-mode)
- [Installation: SSH mode](#installation-ssh-mode)
- [Installation: Headscale mode](#installation-headscale-mode)
- [Post-install: verify](#post-install-verify)
- [Post-install: connect your CLI and IDE](#post-install-connect-your-cli-and-ide)
- [Auto-update](#auto-update)
- [Stopping, restarting, and switching modes](#stopping-restarting-and-switching-modes)
- [Contents](#contents)
- [Requirements](#requirements)
- [Trade-offs](#trade-offs)
- [Acknowledgements](#acknowledgements)
- [Author](#author)
- [License](#license)

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

---

## Prerequisites

All modes share these:

1. **A VPS running [Dokploy](https://dokploy.com).** If you do not have one,
   follow the [Dokploy installation guide](https://docs.dokploy.com/docs/getting-started/install).
2. **SSH access to the VPS** with a non-root user that has sudo.
3. **Generate two secrets** before you start. Run these on any machine and
   save the output:

   ```bash
   # JWT secret (used to sign dashboard session cookies)
   openssl rand -hex 32

   # Initial dashboard password (change it in the UI after first login)
   openssl rand -base64 24
   ```

4. **Know your Dokploy panel URL** (e.g. `https://panel.yourdomain.com`) and
   have it accessible in your browser.

Mode-specific prerequisites are listed in each installation section below.

---

## Installation: Tailscale mode

**Best for:** most users. Real HTTPS URL, least infrastructure, mesh
membership as a second gate.

**Compose file:** `./docker-compose.yml`
**Client URL:** `https://9router.<your-tailnet>.ts.net`

### Prerequisites

- A [Tailscale account](https://login.tailscale.com/start) (free tier is
  sufficient)
- The Tailscale client installed on every machine that will use 9Router
  ([download](https://tailscale.com/download))

### Step 1: Configure Tailscale ACLs

1. Log in to the [Tailscale admin console](https://login.tailscale.com/admin).
2. Go to **DNS** and enable **MagicDNS**.
3. Still under **DNS**, enable **HTTPS Certificates**. This is required for
   `tailscale serve` to issue a TLS certificate.
4. Go to **Access Controls** and replace the default policy with:

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

   > The tag goes in `dst` only. Putting it in `src` as well grants the node
   > access to itself and your own machines nothing. On older tailnets that
   > use `acls` instead of `grants`, use this equivalent:
   >
   > ```jsonc
   > {
   >   "tagOwners": { "tag:nine-router": ["autogroup:admin"] },
   >   "acls": [
   >     { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:nine-router:443"] },
   >   ],
   > }
   > ```
   >
   > Use one style or the other, not both for the same traffic.

### Step 2: Generate a Tailscale auth key

1. In the admin console, go to **Settings** and enable **Device approval**.
2. Go to **Keys** and click **Generate auth key**.
3. Set it to **reusable** and **non-ephemeral**, and tag it `tag:nine-router`.
4. Copy the key. It starts with `tskey-auth-` and is shown only once.

### Step 3: Create the Dokploy project

1. Open your Dokploy panel in a browser.
2. Go to **Create** and select **Compose**.
3. Name the project `9router`.
4. Point it at this repository:
   `https://github.com/ali-rajabpour/9router-gated`
5. Set **Compose Path** to `./docker-compose.yml`.
6. Under **Advanced**, set **Isolated Deployments** to **OFF**. (It injects a
   `networks:` key into every service, which is invalid alongside
   `network_mode` and will fail the deploy.)
7. **Do not add a domain.** No Traefik router, no `dokploy-network`. That is
   the point.

### Step 4: Set environment variables

1. In the Dokploy project, go to the **Environment** tab.
2. Add these variables:

   | Variable | Value |
   |---|---|
   | `TS_AUTHKEY` | The Tailscale auth key from Step 2 |
   | `JWT_SECRET` | The hex string from `openssl rand -hex 32` |
   | `INITIAL_PASSWORD` | The base64 string from `openssl rand -base64 24` |

   > `INITIAL_PASSWORD` is not optional. 9Router falls back to `123456` when
   > it is unset. It is bootstrap-only: once you set a password in the
   > dashboard, that bcrypt hash in SQLite takes precedence.

### Step 5: Add the serve config as a file mount

1. In the Dokploy project, go to **Advanced** and find **Volumes**.
2. Click **Add File Mount** and fill in:

   | Field | Value |
   |---|---|
   | **File Path** | `serve.json` |
   | **Content** | Paste the contents of `serve.json` from this repository |

   > File Path is a bare filename. No leading slash, no directory, no
   > `../files/` prefix. Dokploy writes it to `<project>/files/serve.json`,
   > which is why `docker-compose.yml` mounts it as `../files/serve.json`.
   >
   > Do not mount the repository's `serve.json` directly. Dokploy re-clones
   > the repository on every deploy, so a direct mount works once and then
   > breaks. File Mounts live outside the cloned directory and survive.

### Step 6: Deploy

1. Click **Deploy** in the Dokploy panel.
2. Wait for the containers to start. Dokploy renders every stderr line as an
   error and `tailscaled` logs everything to stderr, so read the state rather
   than the log color.
3. Confirm the sidecar came up. In the Dokploy panel, check the Tailscale
   container logs for a line like:
   `tailscale up: setting hostname to "9router"; ... 100.x.x.x`
4. If device approval is on (Step 2), approve the new node under **Machines**
   in the Tailscale admin console.

### Step 7: Install Tailscale on client machines

1. Install the Tailscale client on each machine that will use 9Router:
   - **macOS:** `brew install tailscale` or download from
     [tailscale.com/download](https://tailscale.com/download)
   - **Windows:** download from
     [tailscale.com/download](https://tailscale.com/download)
   - **Linux:** `curl -fsSL https://tailscale.com/install.sh | sh`
   - **iOS/Android:** App Store / Google Play
2. Log in with the same Tailscale account.
3. If device approval is on, approve each machine in the admin console.
4. Confirm the client can reach 9Router:

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' \
     https://9router.<your-tailnet>.ts.net/v1/models
   # expect 401 (unauthorized, but reachable)
   ```

Your base URL is `https://9router.<your-tailnet>.ts.net`. Proceed to
[Post-install: verify](#post-install-verify).

> **If nothing routes:** The usual cause is device approval (Step 2) - a
> freshly authenticated node sits unapproved until you approve it under
> **Machines**. Also, `serve` fetches the TLS certificate lazily on the first
> HTTPS request, so a slow first load is normal. If it never issues, **DNS
> and HTTPS Certificates** is off.

---

## Installation: SSH mode

**Best for:** networks where Tailscale is filtered, and you want zero extra
infrastructure.

**Compose file:** `./docker-compose.ssh.yml`
**Client URL:** `http://127.0.0.1:20128` (via SSH tunnel)

### Prerequisites

- SSH access to the VPS with key-based authentication
- `autossh` on client machines if you want the tunnel to survive
  sleep/reboots (optional but recommended)

### Step 1: Create the Dokploy project

1. Open your Dokploy panel in a browser.
2. Go to **Create** and select **Compose**.
3. Name the project `9router`.
4. Point it at this repository:
   `https://github.com/ali-rajabpour/9router-gated`
5. Set **Compose Path** to `./docker-compose.ssh.yml`.
6. Under **Advanced**, set **Isolated Deployments** to **OFF**.
7. **Do not add a domain.** No Traefik router, no `dokploy-network`.

### Step 2: Set environment variables

1. In the Dokploy project, go to the **Environment** tab.
2. Add these variables:

   | Variable | Value |
   |---|---|
   | `JWT_SECRET` | The hex string from `openssl rand -hex 32` |
   | `INITIAL_PASSWORD` | The base64 string from `openssl rand -base64 24` |

   > `INITIAL_PASSWORD` is not optional. 9Router falls back to `123456` when
   > it is unset.

### Step 3: Deploy

1. Click **Deploy** in the Dokploy panel.
2. Wait for the container to start.

### Step 4: Confirm the port is loopback-only

This is the single most important check. SSH into the VPS and run:

```bash
ss -tlnp | grep 20128
```

You must see `127.0.0.1:20128`. If you see `0.0.0.0:20128` or `*:20128`, the
`127.0.0.1:` prefix was dropped from the `ports:` entry and 9Router is exposed
to the internet. Stop and fix that before going further.

### Step 5: Open the SSH tunnel from each client

From each client machine, run:

```bash
ssh -N -L 20128:127.0.0.1:20128 <user>@<vps>
```

9Router is now at `http://127.0.0.1:20128` on that machine.

For a tunnel that survives sleep, network changes, and reboots, use `autossh`:

```bash
autossh -M 0 -f -N \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes \
  -L 20128:127.0.0.1:20128 <user>@<vps>
```

> `ExitOnForwardFailure=yes` matters. Without it, a failed forward leaves you
> with a live SSH session and a dead tunnel, which looks like 9Router being
> down.

For a persistent service on **macOS**, create a launch agent at
`~/Library/LaunchAgents/com.local.9router-tunnel.plist`:

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

Then `launchctl load` it.

On **Windows**, create a Task Scheduler task running at logon:

```
Program:   C:\Windows\System32\OpenSSH\ssh.exe
Arguments: -N -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -L 20128:127.0.0.1:20128 USER@VPS
```

Use key-based auth so nothing prompts. A dedicated SSH key with
`command="",no-pty,no-agent-forwarding,permitopen="127.0.0.1:20128"` in
`authorized_keys` restricts that key to this one forward and nothing else.

### Step 6: Harden the SSH server

The tunnel inherits whatever your SSH configuration allows, so it is now part
of this system's security. Confirm in `/etc/ssh/sshd_config` on the VPS:

```
PasswordAuthentication no
PermitRootLogin no
```

Proceed to [Post-install: verify](#post-install-verify).

---

## Installation: Headscale mode

**Best for:** networks where Tailscale is SNI-filtered, and you want a mesh
VPN rather than per-machine SSH tunnels.

**Compose file:** `./docker-compose.headscale.yml`
**Client URL:** `http://100.64.0.2:80` (mesh IP, will vary)

### Prerequisites

- A domain name (or subdomain) you control, with DNS access
- The Tailscale client installed on every machine that will use 9Router
  ([download](https://tailscale.com/download))

### Step 1: Point DNS at your VPS

Create an A record pointing at your VPS public IP:

```
headscale.yourdomain.com  A  <vps-ip>
```

Traefik (managed by Dokploy) will terminate TLS on this hostname automatically.

### Step 2: Create the Dokploy project

1. Open your Dokploy panel in a browser.
2. Go to **Create** and select **Compose**.
3. Name the project `9router`.
4. Point it at this repository:
   `https://github.com/ali-rajabpour/9router-gated`
5. Set **Compose Path** to `./docker-compose.headscale.yml`.
6. Under **Advanced**, set **Isolated Deployments** to **OFF**.
7. **Do not add a domain to 9Router.** (The Headscale container uses
   `dokploy-network` for Traefik routing, but 9Router itself stays private.)

### Step 3: Set environment variables

1. In the Dokploy project, go to the **Environment** tab.
2. Add these variables:

   | Variable | Value | Required? |
   |---|---|---|
   | `JWT_SECRET` | The hex string from `openssl rand -hex 32` | Yes |
   | `INITIAL_PASSWORD` | The base64 string from `openssl rand -base64 24` | Yes |
   | `HEADSCALE_DOMAIN` | `headscale.yourdomain.com` (your actual domain) | Yes |
   | `HEADSCALE_USER` | `9router` (or any name you want) | No (defaults to `9router`) |
   | `HS_AUTHKEY` | Leave empty - the Headscale container generates one automatically | No |

   > `INITIAL_PASSWORD` is not optional. 9Router falls back to `123456` when
   > it is unset. `HEADSCALE_DOMAIN` is substituted into the Headscale config
   > at container startup - no file editing needed.
   >
   > **No SSH to the VPS is required for setup.** The Headscale container
   > creates the user and pre-auth key automatically on first start, writes
   > the key to a shared volume that the Tailscale sidecar reads, and prints
   > the key to its container logs for your visibility.

### Step 4: Deploy

1. Click **Deploy** in the Dokploy panel.
2. Watch the container logs in the Dokploy panel. On first start you will
   see, in the Headscale setup container logs:

   ```
   ========================================
   Headscale pre-auth key created: hskey-auth-xxxxxxxxx
   The Tailscale sidecar will use it automatically.
   ========================================
   ```

   The Tailscale sidecar waits for this key, then joins the mesh automatically.
   No SSH, no manual key generation, no second deploy.

3. Wait for all containers to show as running. The sidecar may take 10-30
   seconds to come up after Headscale issues the key.

### Step 5: Find the sidecar's mesh IP

The mesh IP is the base URL for all your clients. You have two ways to find
it, neither requires SSH:

**Option A - from the Dokploy panel:**

1. In the Dokploy project, find the Tailscale container.
2. Open its logs. Look for a line like:
   `tailscale up: setting hostname to "9router"; ... 100.64.0.2`

**Option B - from a client machine (after Step 7):**

Once a client is on the mesh (Step 7), run:

```bash
tailscale status
```

Look for the `9router` node and note its IP (e.g. `100.64.0.2`).

Your base URL is `http://<mesh-ip>:80` (e.g. `http://100.64.0.2:80`).

### Step 6: Enroll client machines

On each client machine that will use 9Router:

1. Install the Tailscale client:
   - **macOS:** `brew install tailscale` or download from
     [tailscale.com/download](https://tailscale.com/download)
   - **Windows:** download from
     [tailscale.com/download](https://tailscale.com/download)
   - **Linux:** `curl -fsSL https://tailscale.com/install.sh | sh`
   - **iOS/Android:** App Store / Google Play

2. Join your Headscale (not Tailscale's hosted control plane):

   ```bash
   tailscale up --login-server https://headscale.yourdomain.com
   ```

   This opens a browser for first-time authentication. After that, the
   machine is on your mesh permanently.

3. Confirm the client can reach 9Router:

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' http://100.64.0.2:80/v1/models
   # expect 401 (unauthorized, but reachable)
   ```

   A 401 means 9Router is reachable from the mesh and requires an API key -
   exactly right. A connection refused or timeout means the mesh is not up
   yet; wait a minute and retry.

Proceed to [Post-install: verify](#post-install-verify).

> **The HTTPS gap:** Headscale does not support per-node TLS certificate
> provisioning, so `tailscale serve` runs in HTTP mode and `AUTH_COOKIE_SECURE`
> is `false`. WireGuard encrypts the transport between mesh nodes, so traffic
> is encrypted in transit - the HTTP is only plaintext inside the sidecar's
> loopback. CLI tools (Claude Code, curl, etc.) accept `http://` URLs fine.
> If a client requires `https://`, run a local reverse proxy on the client
> machine:
>
> ```bash
> # Install Caddy, then:
> caddy reverse-proxy --from localhost:8443 --to http://100.64.0.2:80 \
>   --internal-certs
> ```
>
> This gives you `https://localhost:8443` with a self-signed cert that
> forwards to the mesh IP over WireGuard.

---

## Post-install: verify

From a client machine, against your mode's base URL:

```bash
./verify.sh https://9router.<your-tailnet>.ts.net   # Tailscale
./verify.sh http://127.0.0.1:20128                  # SSH, tunnel up
./verify.sh http://100.64.0.2:80                    # Headscale, mesh IP
```

Expected: `/v1/models` returns 401, `/api/mcp/` returns 403, `/api/settings`
returns 401, `/dashboard` returns 307. A bare hostname is accepted and assumed
to be HTTPS. `./verify.sh --self-test` checks the script itself without
contacting a server.

**A 200 on the first check means the loopback hop leaked local privileges.**
Anyone who can reach 9Router can then spend your provider subscriptions and
read the tokens. Stop and fix it before connecting anything.

On the VPS, confirm what is published to the host:

```bash
ss -tlnp | grep -E '20128|8787'
# Tailscale mode:  no output.
# SSH mode:        127.0.0.1:20128 only.
# Headscale mode:  no output (9router in sidecar netns).
```

## Post-install: connect your CLI and IDE

1. Open your base URL in a browser, log in with `INITIAL_PASSWORD`, and change
   the password immediately.
2. Connect providers: Dashboard and then Providers.
3. Generate an API key: Dashboard and then API keys.
4. Enable Headroom: Endpoint and then Token Saver and then Headroom. The URL
   should already read `http://headroom:8787`; recheck status, then enable.

Point clients at `<base-url>/v1` with that API key. Claude Code:

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:20128     # or the ts.net / mesh IP URL
export ANTHROPIC_AUTH_TOKEN=<9router key>
```

Hermes, via `hermes model` and then **Custom endpoint**, or directly:

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

> Cursor routes some requests through its own backend, which cannot reach a
> private endpoint. That is a Cursor limitation and applies to all three
> modes.

## Auto-update

You cannot webhook this. Docker Hub webhooks are configured by the repository
owner, and `decolua/9router` is not yours, so there is no push event to
subscribe to. Watchtower would work but requires mounting the Docker socket,
which is root-equivalent on a host running your other projects. Not worth it.

Polling instead. **Dokploy and then Schedule Jobs and then Create**:

- Schedule: `0 */6 * * *` (adjust to taste)
- Command:

  ```bash
  curl -fsS -X POST 'https://<your-dokploy-panel>/api/compose.deploy' \
    -H 'x-api-key: <dokploy-api-key>' \
    -H 'Content-Type: application/json' \
    -d '{"composeId":"<composeId from the project URL>"}'
  ```

`pull_policy: always` in all three compose files makes the re-pull explicit
rather than incidental. Confirm the exact endpoint name against your panel's
`/swagger`. It has been `compose.deploy` in recent versions.

**Understand what you turned on.** Tracking `:latest` with an unattended
redeploy means an upstream compromise reaches your provider OAuth tokens
without review. If that stops being acceptable, pin a version tag and drop
the scheduled job.

## Stopping, restarting, and switching modes

Dokploy Stop halts the containers; volumes persist.

| Volume | Contents |
|---|---|
| `9router-data` | `db/data.sqlite`, provider OAuth tokens, API keys, `jwt-secret`, certs, backups |
| `tailscale-state` | Tailscale/Headscale modes: node identity, serve config, TLS certificate (Tailscale mode only) |
| `headscale-data` | Headscale mode only: control plane database, noise private key, DERP private key |

Start returns the same configuration, and in Tailscale mode the same hostname
and certificate. The auth key is consumed only on first run. In Headscale
mode, the Headscale database and keys persist, so the control plane survives
restarts without re-initialization.

Do not delete these volumes. `9router-data` is your entire configuration; if
`JWT_SECRET` were ever unset, it would also hold the auto-generated secret.

**Switching modes:** Change **Compose Path** and redeploy. All three files
declare a `9router-data` volume with the same name, so within one Dokploy
project your database, provider connections, and API keys carry across. Set
`TS_AUTHKEY` for Tailscale mode, or `HEADSCALE_DOMAIN` for Headscale mode (the
pre-auth key is auto-generated). Run `verify.sh` again against the new base
URL.

## Contents

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | Tailscale mode: sidecar, 9Router, Headroom |
| `docker-compose.ssh.yml` | SSH mode: 9Router bound to host loopback, Headroom |
| `docker-compose.headscale.yml` | Headscale mode: Headscale + sidecar, 9Router, Headroom |
| `serve.json` | `tailscale serve` config (Tailscale mode), mounted via Dokploy |
| `.env.example` | The required secrets |
| `verify.sh` | Post-deploy assertions that privileges did not leak |
| `DEPLOY.md` | Full runbook for all three modes |
| `docs/DESIGN.md` | Design rationale, upstream review, rejected alternatives |

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
get no per-node TLS certificate - `tailscale serve` runs in HTTP mode, so
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

[MIT](LICENSE) (c) Ali Rajabpour Sanati
