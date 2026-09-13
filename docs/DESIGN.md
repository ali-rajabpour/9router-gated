# Design notes

Why this deployment looks the way it does, what was rejected, and what to
re-check if upstream changes.

## Requirements

Run 9Router on a Dokploy-managed VPS that already hosts unrelated production
projects. Reachable from Windows and macOS desktop clients and their IDEs.
Automatic updates from upstream. Configuration and credentials must survive
stop/start cycles. Single operator.

Security was the binding constraint: the deployment was to be abandoned if it
could not be made safe.

## Upstream review

Read from source at `decolua/9router@master` rather than from documentation.
`src/dashboardGuard.js` implements the entire authorization model:

- `/api/*` is deny-by-default with a short public allow-list (`/api/health`,
  `/api/init`, `/api/auth/login`, `/api/version`, …).
- `/dashboard/*` requires a JWT cookie. `requireLogin` defaults to `true`
  (`src/lib/db/repos/settingsRepo.js:20`).
- `/v1`, `/v1beta`, `/api/v1`, and `/codex` are public prefixes, but remote
  callers must present a valid API key. Loopback callers bypass that check.
- `LOCAL_ONLY_PATHS`, covering routes that spawn child processes or read host
  secrets (`/api/mcp/`, `/api/cli-tools/*`, `/api/tunnel/*`,
  `/api/auth/reset-password`, `/api/headroom/*`), returns 403 to anything not
  local.
- `custom-server.js` deletes client-supplied `x-9r-real-ip`, `x-9r-via-proxy`,
  and `x-forwarded-for` before stamping values derived from the TCP socket, so
  header spoofing cannot forge a loopback origin.
- `src/lib/auth/loginLimiter.js` applies progressive lockout: five failures,
  then 30s / 2m / 10m / 30m.

Findings that shaped the design:

1. `INITIAL_PASSWORD` falls back to `123456`. Must be set explicitly.
2. `JWT_SECRET`, when unset, is generated into `$DATA_DIR/jwt-secret`, which is
   safe only while the volume persists.
3. `REQUIRE_API_KEY` is documented in upstream's `.env.example` but has **no
   references anywhere in `src/`**. It is dead. API-key enforcement for remote
   `/v1` callers is unconditional and does not depend on it. Do not rely on
   that variable.
4. Blast radius is high. The database holds OAuth tokens for Claude, Copilot,
   Cursor, and Kiro. Compromise means subscription abuse and token theft.
5. Behind a shared reverse proxy the login limiter keys on the proxy's address,
   collapsing every client into one bucket. Tolerable for one user, but an
   argument against fronting the service with Traefik.

Conclusion: safe to run, given a strong bootstrap password and a persistent
volume, provided it is not exposed publicly.

## Options considered

| Option | Verdict |
| --- | --- |
| Public domain, Traefik, 9Router auth only | Rejected. One layer in front of live provider OAuth tokens. |
| Public domain + Cloudflare Access on dashboard paths | Rejected. Leaks the origin IP, and `:443` answers the world, so anyone who finds the address reaches every other vhost on the box directly. |
| Cloudflare Tunnel + Access | Rejected. IDEs cannot carry Access identity, so `/v1` needs a bypass rule and reverts to API-key-only. Decisive objection: TLS terminates at Cloudflare's edge, so prompts, source, and tokens transit their infrastructure in plaintext. |
| Tailscale installed on the host | Rejected. Adds a root daemon and rewrites `/etc/resolv.conf` on a production server. |
| **Tailscale as a sidecar container** | **Chosen as the default.** |
| **SSH local port forward** | **Chosen as the fallback**, for networks where Tailscale is filtered. |
| **Headscale (self-hosted control plane)** | **Chosen as the second fallback**, for networks where Tailscale is filtered and a mesh is preferred over per-machine tunnels. |

The deciding argument: in every publicly-exposed option, `/v1` must stay
reachable by clients that authenticate with a bearer token alone, so no
identity proxy can gate it. Removing the public exposure entirely is the only
mechanism that works without breaking the clients. Tailnet membership does
that; so does an SSH tunnel.

## Architecture

Tailscale mode, one Dokploy Compose stack, three containers:

```
tailnet ──TLS 443──> [tailscale sidecar] ──127.0.0.1:20128──> [9router]
                            │  (shared netns)                     │
                            └── docker bridge ────────────> [headroom :8787]
```

SSH mode, two containers:

```
client ──SSH──> [vps 127.0.0.1:20128] ──bridge──> [9router] ──> [headroom :8787]
```

Headscale mode, four containers:

```
mesh ──HTTP 80──> [tailscale sidecar] ──127.0.0.1:20128──> [9router]
                       │  (shared netns)                     │
                       └── docker bridge ────────────> [headroom :8787]

headscale.yourdomain.com ──HTTPS 443──> [headscale]  (control plane + DERP, public)
```

None of the three publishes a 9Router port reachable from the internet, creates
a Traefik route for 9Router, or needs a public DNS record for 9Router. Headscale
mode adds one public service — the Headscale control plane — but 9Router itself
stays private.

### Namespace sharing

9Router runs with `network_mode: "service:tailscale"`. The `tailscale0`
interface exists only inside that namespace, leaving the host's routing table,
resolver configuration, firewall, and Docker's iptables chains untouched.
Deleting the stack leaves nothing behind.

For reference, a host-level install would have touched: addresses from
`100.64.0.0/10` (no overlap with Docker's ranges), MagicDNS rewriting
`/etc/resolv.conf`, and new `ts-input` / `ts-forward` / `ts-postrouting`
firewall chains. The default route would have been unaffected unless an exit
node was configured. The sidecar makes all of that moot.

### The loopback privilege question

`tailscale serve` proxies over loopback, and 9Router grants local requests
elevated access. This is safe only because `serve` sets forwarding headers.
Verified in `tailscale/tailscale`, `ipn/ipnlocal/serve.go`:
`addProxyForwardedHeaders` is called unconditionally from the proxy's `Rewrite`
hook and sets `X-Forwarded-For` to the client's mesh address along with
`X-Forwarded-Proto` (https for Tailscale mode, http for Headscale mode).

```
client 100.x → serve (TLS :443 or HTTP :80) → XFF=100.x, XFP=…
  → 127.0.0.1:20128 → custom-server.js: loopback peer + XFF present
  → stamps x-9r-real-ip=100.x, x-9r-via-proxy=1
  → dashboardGuard.isLocalRequest() = false
```

`/v1` still requires an API key and the local-only routes still return 403.
Two incidental benefits over a Traefik fronting: the rate limiter gets real
per-client buckets, and `X-Forwarded-Proto: https` (Tailscale mode) makes
`AUTH_COOKIE_SECURE` behave correctly. In Headscale mode, `X-Forwarded-Proto`
is `http`, so `AUTH_COOKIE_SECURE` is `false` — matching SSH mode.

**If upstream changes either `custom-server.js`'s header handling or
`dashboardGuard.isLocalRequest`, re-run `verify.sh` before trusting the
deployment.**

### Headroom placement

Headroom stays outside the shared namespace on purpose. Inside it, it could
reach `127.0.0.1:20128` without an `X-Forwarded-For` header and be treated as
a local request, unlocking keyless `/v1`, `/api/auth/reset-password`, and the
process-spawning routes. On the Docker bridge it reaches 9Router at a
non-loopback address and is treated as remote. It is a third-party image and
gets no implicit trust.

### Least privilege

The sidecar runs in userspace mode (`TS_USERSPACE=true`), requiring neither
`NET_ADMIN` nor `/dev/net/tun`. `serve` functions normally in that mode.

## The SSH access mode

Added after the Tailscale build shipped, because Tailscale turned out to be
filtered on the operator's network.

### What the filter actually does

Measured rather than assumed:

| Observation | Result |
| --- | --- |
| DNS for `controlplane` / `login.tailscale.com` | Resolves correctly to the real anycast range (`192.200.0.0/24`). No poisoning. |
| TCP 443 to those addresses | Connects. |
| TLS ClientHello with SNI under `tailscale.com` | Immediate RST. |
| Same SNI directed at an unrelated address | Also RST. |
| Any other SNI to that same address | Answers normally. |
| SNI `tailscale.io`, `headscale.net`, `wireguard.com`, `netbird.io` | All answer normally. |

So it is an SNI keyword filter on one domain, not protocol fingerprinting and
not IP blocking. Tailscale specifically is unreachable, because the control
plane and every DERP relay share that domain. WireGuard as a protocol is not
being touched.

Headscale was originally rejected, since a self-hosted control plane on an
unrelated domain would not match the SNI filter. The original objections were:
it does not support `tailscale serve` with HTTPS or per-node `tailscale cert`
(juanfont/headscale#1921, tagged `tailscale-feature-gap`), the default DERP map
still points at `*.tailscale.com` so a self-hosted DERP is needed too, and the
result is a new public-facing control plane on the same production box the
design was trying to keep clean.

Headscale was later **un-rejected** and added as a third access mode, for users
who need a mesh (not per-machine tunnels) and whose network filters Tailscale.
The objections were addressed as follows:

- **No HTTPS serve**: `tailscale serve` runs in HTTP mode on port 80. WireGuard
  encrypts the mesh transport, so traffic is encrypted in transit. Clients that
  require `https://` need a local TLS terminator. `AUTH_COOKIE_SECURE` is
  `false`, matching SSH mode.
- **Self-hosted DERP**: the embedded DERP relay in Headscale is used, with
  `urls: []` to avoid Tailscale's public DERP servers (which live on
  `*.tailscale.com` and are filtered). STUN is configured but its UDP port is
  not published, so clients relay through DERP over HTTPS/443 — pure HTTPS,
  no UDP, maximum censorship resistance.
- **New public-facing control plane**: accepted as the trade-off. Headscale is
  the one public service in the stack. 9Router itself stays private. The
  control plane does not hold 9Router secrets, but a compromise lets an
  attacker enroll rogue nodes, so it should be hardened (SSH key-only, Fail2Ban,
  restricted API access).

Three moving parts to replace one tunnel — but for users who need a mesh and
cannot reach Tailscale's hosted control plane, it is the right trade.

SSH was already reachable on both 22 and 443, needs no new infrastructure, and
adds no new listening service.

### The source-address question

The same loopback privilege problem appears in a different form. The port is
published as `127.0.0.1:20128:20128`, and if the container observed the peer
address as `127.0.0.1` it would grant every tunnelled request local
privileges.

It does not, because Docker's userland proxy accepts the connection on the
host and opens a fresh one to the container, which therefore sees the bridge
gateway address. `userland-proxy` defaults to enabled.

If it has been disabled in `/etc/docker/daemon.json`, the DNAT path can
preserve the original source address and the assumption breaks. That is the
one host-level configuration this mode depends on, it is checkable with a
single grep, and `verify.sh` fails loudly if it is wrong. Documented in
`DEPLOY.md` §B4.

### What is given up

No TLS, so `AUTH_COOKIE_SECURE` is `false` and clients that require an
`https://` base URL need a local terminator. No tailnet membership layer;
the gate becomes the VPS's SSH configuration, which makes key-only
authentication load-bearing rather than merely advisable. Residual risk: anyone
with a shell on the VPS reaches 9Router over host loopback, leaving only the
dashboard password and API key. Acceptable for a single-operator box, and worth
stating plainly rather than burying.

The two modes share volume names, so switching is a compose-path change plus a
redeploy.

## Persistence

| Volume | Contents | Rationale |
| --- | --- | --- |
| `9router-data` → `/app/data` | `db/data.sqlite`, provider OAuth tokens, API keys, `jwt-secret`, certificates, backups | the entire configuration |
| `tailscale-state` → `/var/lib/tailscale` | node identity, serve config, TLS certificate | Tailscale/Headscale modes: same hostname and certificate (Tailscale) or node identity (Headscale) after restart, no re-authentication |
| `headscale-data` → `/var/lib/headscale` | control plane database, noise private key, DERP private key | Headscale mode only: control plane survives restarts without re-initialization |

The auth key is consumed on first run only. `--advertise-tags=tag:nine-router`
disables key expiry for the node, so a stack left stopped for months still
restarts cleanly.

## Updates

Registry webhooks are not possible here: Docker Hub webhooks are configured by
the repository owner, and `decolua/9router` belongs to upstream. There is no
push event to subscribe to.

Watchtower was rejected because it requires mounting the Docker socket, which
is root-equivalent on a host running unrelated production projects.

Chosen mechanism: a Dokploy scheduled job on a cron calling Dokploy's own API
to redeploy, with `pull_policy: always` making the re-pull explicit rather than
incidental.

Accepted risk: tracking `:latest` with an unattended redeploy means an upstream
compromise reaches the provider OAuth tokens without review. Mitigation if that
becomes unacceptable: pin a version tag and delete the scheduled job.

## Verification

`verify.sh` takes the base URL of whichever mode is deployed and asserts:
`/v1/models` → 401, `/api/mcp/` → 403, `/api/settings` → 401, `/dashboard` →
307. A 200 on the first means the central assumption has broken.

On the host, `ss -tlnp | grep -E '20128|8787'` must return nothing in Tailscale
and Headscale modes, and exactly `127.0.0.1:20128` in SSH mode.
`0.0.0.0:20128` means the loopback prefix was lost from the `ports:` entry and
the service is public.

## To confirm against your installed versions

- Dokploy's File Mount path convention (`../files/serve.json`).
- Dokploy's Compose Path field, which is what selects the access mode.
- The exact Dokploy API endpoint for compose redeploy, via the panel's
  `/swagger`.
