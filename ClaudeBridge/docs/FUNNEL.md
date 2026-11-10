# Stage 3: Tailscale (tsnet) and Funnel

Status on 2026-11-10: the Go side is written and unit-tested on the Mac, builds
as a static iOS library, and links into the runner (the `.xctest` binary is
about 25 MB). **It has not yet been run on the phone**: that needs a Tailscale
auth key and the tailnet policy below.

## How it fits together

```
Claude ──HTTPS──▶ Tailscale Funnel relay ──(encrypted)──▶ tsnet inside the runner
                                                          │ TLS ends here, on the phone
                                                          ▼
                                             reverse proxy (Go, ClaudeBridge/go)
                                                          │ http://127.0.0.1:8220
                                                          ▼
                                             MCP listener (Swift): secret check, tools
```

- **tsnet is its own tailnet device** inside the runner process. It is
  userspace networking: no VPN profile, no conflict with the Tailscale app or
  LocalDevVPN, no entitlement.
- **TLS terminates on the phone.** Funnel relays forward ciphertext, so the
  URL secret in the request path is never visible to Tailscale.
- **Funnel only.** The listener uses `tsnet.FunnelOnly()`, so other devices on
  your tailnet cannot reach it directly either. The one way in is the public
  URL with the secret.
- **The Go side has no logic.** It forwards to the loopback MCP listener and
  answers the generic `404 page not found` if that listener is down. It logs
  nothing, and it turns off uploading of node logs to Tailscale.
- **The raw API is pinned to loopback in this mode.** `JSONRPCServer` is
  created local-only whenever Funnel mode is on, whatever the remote-access
  setting says, so "tap anywhere" can never be reachable from the network
  while the phone has a public endpoint.
- **Stops with the runner.** `ClaudeBridgeRunner.stop()` closes the tsnet
  node first, then the MCP listener. Nothing is reachable while the runner is
  off.

## One-time Tailscale setup

1. **Enable HTTPS and MagicDNS** for the tailnet (admin console → DNS).
   Funnel needs both.
2. **Add this to the tailnet policy file** (admin console → Access controls):

   ```jsonc
   {
     "tagOwners": {
       "tag:ictrl": ["autogroup:admin"]
     },
     "nodeAttrs": [
       { "target": ["tag:ictrl"], "attr": ["funnel"] }
     ]
   }
   ```

   Merge these keys into your existing policy; do not replace it. The tag
   owner lets you create keys for `tag:ictrl`; the node attribute lets devices
   with that tag use Funnel. Nothing else needs to be granted: the bridge
   accepts no connections from tailnet peers, so no ACL rule points at it.
3. **Create an auth key** (admin console → Settings → Keys → Generate auth
   key): tag `tag:ictrl`, **not** reusable, **not** ephemeral, short expiry
   (it is used once). A tagged device has key expiry disabled, so the phone
   stays joined.
4. **Give the key to the runner.** Until the companion screen exists (Stage
   6), a development run takes it from the Xcode scheme:

   | Variable | Value |
   |---|---|
   | `ICTRL_BRIDGE_FUNNEL` | `1` |
   | `ICTRL_BRIDGE_TS_AUTHKEY` | the `tskey-auth-…` key (first run only) |
   | `ICTRL_BRIDGE_DEV_SECRET` | a URL secret of 32 or more characters |

   After the first successful start the node key is stored on the phone and
   the auth key is no longer needed.

The public URL is then `https://ictrl-phone.<tailnet>.ts.net/<secret>/mcp`.
The host name is fixed (`ictrl-phone`, changeable with the
`claudeBridge.hostname` default), and the node's state is kept in the runner's
Application Support, so the URL is the same after a restart or reboot. The
first start takes longer: the node logs in and obtains a certificate.

## Where things are stored on the phone

| What | Where | Notes |
|---|---|---|
| URL secret | Runner keychain, `ThisDeviceOnly` | Never logged, never returned by a tool |
| Tailscale auth key | Runner keychain, `ThisDeviceOnly` | Used once |
| tsnet node key, TLS certificate | `Application Support/ClaudeBridge/tsnet/` in the runner | Files, excluded from backup, protected until first unlock. tsnet needs a directory; these cannot live in the keychain |

None of it is ever in the repository; `ClaudeBridge/.gitignore` and the
pre-commit hook are a safety net for copies made on the Mac.

## Building

`make build` builds the Go library first (through `ClaudeBridge/bridge.mk`)
when its sources change. By hand:

```bash
ClaudeBridge/go/build-ios.sh
```

Tests for the proxy:

```bash
cd ClaudeBridge/go && go test ./...
```

After adding a new Swift file under `ClaudeBridge/`, regenerate the project
(`xcodegen generate`); `make` only does so when `project.yml` changes.

## Still to verify on the phone

1. The Go runtime runs alongside XCTest in the runner without disturbing it.
2. Login with the tagged key, and Funnel answering from outside.
3. Certificate issue time on first start, reuse on later starts.
4. Memory and idle CPU with tsnet running.
5. The endpoint survives an hour in the background, on Wi-Fi and cellular.
6. Stopping the runner removes the endpoint; the old URL then fails.
7. With Funnel mode on, port 8200 refuses LAN connections even if remote
   access was enabled before.

## Keep-awake while a session runs

Added alongside this stage. A backgrounded runner cannot switch off the idle
timer, so while the bridge runs it sends a tiny touch after about 12 seconds of
inactivity: a tap on the last point of the bottom edge, under the home
indicator. A tool call counts as activity and postpones it.

It only fires while the home screen, system search or an allowlisted app is
in front. During a lockout nothing is touched, so the phone can auto-lock
then. It is on by default with the bridge; set the `claudeBridge.keepAwake`
default to false (or `ICTRL_BRIDGE_KEEP_AWAKE=0` for one run) to let the
phone lock as usual.

Tested on the phone (iOS 27.2, Auto-Lock at 30 seconds): with pulses about
every 16 seconds the phone stayed unlocked on the home screen; without a
timely pulse it locked at 29 seconds. A pulse first reads the foreground,
which on the home screen takes about a second of work each time. Still to
check: that the tap is harmless inside WhatsApp and in search over a long
session, and the battery cost.
