# Stage 1: can tsnet + Funnel run inside the iCTRL runner?

Checked against upstream iCTRL v1.98.16 and Tailscale 1.105 source on
2026-11-10. Nothing here has been run on a device yet; the last section lists
what only a device spike can prove.

## Verdict

**Viable on paper, no blocker found.** The runner is the right place for it.
It needs a device spike before Stage 3 is built on top of it.

## Why the runner is a good host

| Question | Finding |
|---|---|
| Process model | The runner is an ordinary app process (`iCTRLUITests-Runner.app` hosting the `.xctest`). It backgrounds itself with `-[UIApplication suspend]` and keeps running because it is an XCTest runner under `testmanagerd`. It uses no background modes or keep-alive tricks. Goroutines in the same process keep running with it. |
| VPN slot | tsnet is userspace networking (gVisor netstack over ordinary UDP/TCP sockets). No NetworkExtension, no VPN profile, so it does not use iOS's single VPN slot and does not conflict with the Tailscale app or LocalDevVPN. LocalDevVPN is only needed while the DDI is being mounted and only routes `10.7.0.0/24`. |
| Entitlements | None needed. The runner is signed with only `application-identifier`, team id, `get-task-allow` and a keychain group. Outbound sockets need no entitlement. Funnel traffic arrives over tsnet's own outbound connections (DERP or direct), so nothing listens on a public port of the phone. |
| TLS certificates | **Corrected after the device test.** `feature/acme` is compiled into an iOS build, but tsnet fetches the certificate through the LocalAPI cert endpoint, which is excluded on iOS, so the default path fails. The bridge asks the backend directly instead; see FUNNEL.md. |
| iOS support | tsnet builds for iOS; Tailscale's own `libtailscale` ships an iOS Swift package on top of it. `libtailscale`'s C API has no Funnel call, so the bridge needs its own small Go wrapper. |
| Memory | The runner is not an app extension, so it has a normal app memory limit, not the tight NetworkExtension one. Expect tens of MB for tsnet. iCTRL already reports `process_memory_mb` in `device_info`, which the spike will use. |
| Cellular | Works. Funnel reaches the node through Tailscale's relays, so no LAN or Local Network permission is involved. |

## How it would be built

- **Go side (`ClaudeBridge/go/`)**: about 150 lines. Start a `tsnet.Server`
  (fixed hostname, state dir in the runner sandbox, auth key passed in),
  `ListenFunnel("tcp", ":443", tsnet.FunnelOnly())`, and reverse-proxy every
  connection to `127.0.0.1:<bridge port>`. `FunnelOnly` means tailnet peers
  cannot reach it either. Exposes `Start`, `Stop` and `Status` as C functions.
- **Packaging**: `go build -buildmode=c-archive` for `ios/arm64`, wrapped in a
  static xcframework and linked into the `.xctest` with
  `framework: …, embed: false` (the same pattern upstream uses for
  `IDevice.xcframework`). Static, because the Makefile's re-sign step only
  covers `Frameworks/*.dylib`. Plain c-archive is simpler than gomobile: no
  generated Objective-C bindings.
- **Swift side (`ClaudeBridge/Runner/`)**: the MCP server, auth check,
  allowlist and lockout. It listens on loopback only and calls iCTRL's
  existing in-process RPC entry point (`JSONRPCServer.onRPCRequest`, the same
  closure HTTP clients go through, so it shares the serial queue, watchdog and
  circuit breaker). No envelope crypto is involved and the raw API is never
  proxied.

## Upstream hook points this will need (Stages 2 to 6)

| File | Hook |
|---|---|
| `iCTRLUITests/iCTRLUITests.swift` | One line to start the bridge after the listener is up (near line 468), one to stop it after the run loop exits (near line 530), one in `tearDownWithError`. One guard so remote access cannot be switched on while the bridge is live. |
| `project.yml` | Add `ClaudeBridge/Runner` and `ClaudeBridge/App` source paths and the static framework dependency. |
| `iCTRLApp/Models/RunnerAdmin.swift`, `iCTRLApp/Views/RunnerAdminViews.swift` | The fourth visibility case (enum case, params branch, menu entry, label). |
| `iCTRLApp/Views/SettingsView.swift` | One line for the Claude Bridge section. |
| `Makefile` | One line to build the Go archive before `xcodebuild`. |

`iCTRLUITests/Localized.swift` is shared and changes often upstream, so bridge
strings will live in a bridge-owned file instead.

## Things that differ from the original brief

1. **Secrets cannot live only in "the" keychain.** The companion app and the
   runner are separate apps with no App Group and no shared keychain group.
   The runner is the process that needs the URL secret and the Tailscale auth
   key. Plan: the companion sends them to the runner once over the existing
   paired, encrypted loopback channel, and the runner stores them in its own
   keychain (`ThisDeviceOnly`).
   Upstream stopped using the runner keychain for its own session keys
   because SideStore re-signing can change the keychain access group and
   orphan the items. With a paid developer account this does not happen.
2. **tsnet state is files, not keychain.** tsnet keeps its node key and TLS
   certificates in a directory. It will sit in the runner's Application
   Support, excluded from backup, with file protection. It never leaves the
   phone and is gitignored by pattern.
3. **Start Session cannot be fully headless.** The only way to start the
   runner is opening its `ictrl://start` URL, which needs the companion in the
   foreground. The Start intent will open the app (`openAppWhenRun`); the
   krkr521 fork does the same. Stop and Remount DDI can run without opening it.
4. **Live Activity detail is limited.** It needs a new widget extension
   target, and upstream's `sign-ipa.sh` / release packaging strip extension
   entitlements. Also, the runner cannot update the activity directly: the
   companion app is suspended in the background and there is no shared
   container. Without push updates (paid account plus a push sender), the
   activity can show "session live" with a timer and a Stop button, but not
   per-tool state in real time. The runner's own status notification can
   carry the live state instead. To be settled in Stage 6.
5. **Control Centre / Notification Centre are not distinguishable today.**
   iCTRL reports them simply as SpringBoard in front, the same as the home
   screen. The bridge needs its own check (for example a bounded SpringBoard
   snapshot looking for home-screen icons) before treating SpringBoard as
   "home". To be designed in Stage 5.
6. **Runner size.** The runner IPA is about 1 MB today. Linking tsnet will add
   roughly 15 to 25 MB (estimate, not measured).

## Claude connector authentication (checked 2026-11-10)

Claude's custom connector dialog now has a **Request headers** section for
fixed credentials such as `Authorization: Bearer …`. It is in beta and
"available to a limited set of organizations"; if the section is not in your
dialog, you do not have it. Authentication settings, headers included, cannot
be edited after the connector is added (remove and re-add), whereas the URL
can be edited in place.

Plan: keep the URL-path secret as the primary method, since it works for every
account and rotation is a URL edit. Build the auth check as a small module
with two implementations: path secret (default), and path secret plus bearer
header (optional, for accounts that have Request headers). OAuth 2.1 can be
added later as a third.

Source: https://claude.com/docs/connectors/custom/remote-mcp

## What only a device spike can prove

A throwaway build that links the Go archive into the runner and serves
"hello" over Funnel, checking:

1. The Go runtime coexists with XCTest in the runner (Go installs its own
   signal handlers; the runner has its own too).
2. tsnet logs in with a tagged auth key and Funnel answers from outside.
3. First certificate issue time, and that the certificate is reused after a
   runner restart.
4. Memory (`process_memory_mb`) idle and under load, and idle CPU.
5. The endpoint survives the runner being backgrounded with the screen off
   for an hour, on Wi-Fi and on cellular.
6. Stopping the runner removes the endpoint.

Tailscale issue tailscale/tailscale#20060 reports an embedded node going stale
after iOS suspends the process. The runner is not suspended, so it should not
apply, but check 5 covers it.

## If the spike fails

No alternative keeps "no computer at runtime" and "Funnel" both intact:

- tsnet in the companion app: iOS suspends the app in the background, so the
  endpoint would die within seconds.
- The Tailscale iOS app: it cannot run Funnel, and it takes the VPN slot.
- A relay on another always-on machine (a small VPS or home server running
  Funnel or a tunnel, reaching the phone over the tailnet): works, but it is a
  computer at runtime and still needs something on the phone to join the
  tailnet.

The closest fallback would be a different embedded tunnel client in the runner
(same architecture, different provider), losing the stable `ts.net` hostname
and Tailscale-managed certificates.
