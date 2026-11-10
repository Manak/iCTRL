# Claude Bridge: changes to upstream files

This fork adds a "Claude via Funnel" bridge to iCTRL. Almost all of it lives in
new files that upstream does not know about. This file lists **every edit to a
file that upstream owns**, so a merge conflict can be resolved by re-applying a
known, small change.

Rules for this list:

- Every edit to an upstream file is marked in the code with `CLAUDE-BRIDGE HOOK`.
- `git grep -n "CLAUDE-BRIDGE HOOK" -- . ':!ClaudeBridge' ':!CLAUDE_BRIDGE_CHANGES.md'`
  must match the table below exactly. If it doesn't, one of them is wrong.
- When resolving a conflict: take upstream's version of the surrounding code,
  then re-apply the marked line(s).

## Upstream files touched

| File | Hook | Why |
|---|---|---|
| `iCTRLUITests/iCTRLUITests.swift` | In `testStartServer`, after `requestLocalNetworkAtLaunch()`: a 3-line call to `ClaudeBridgeRunner.shared.start { … }` that forwards to `server?.onRPCRequest`. | Starts the bridge once the raw listener is up, and hands it iCTRL's in-process RPC entry point. Does nothing unless the bridge is enabled. |
| `iCTRLUITests/iCTRLUITests.swift` | In `testStartServer`, after `safetyTimer.invalidate()`: `ClaudeBridgeRunner.shared.stop()`. | Stops the bridge on every path that ends the run loop. |
| `iCTRLUITests/iCTRLUITests.swift` | In `tearDownWithError`, after the log line: `ClaudeBridgeRunner.shared.stop()`. | Stops the bridge if XCTest tears the test down directly. |
| `iCTRLUITests/iCTRLUITests.swift` | In the `onRPCRequest` closure, between the `config` branch and the `actionHandler` branch: `else if method == ClaudeBridgeAdmin.method { result = ClaudeBridgeAdmin.handle(params) }`. | Routes the companion's `claude_bridge` method (mode, address, rotation, auth key) to the bridge. |
| `iCTRLUITests/iCTRLUITests.swift` | First line of `postStatusNotification`: `if ClaudeBridgeRunner.shared.statusNotificationSuppressed { return }`. | Withholds the "server ready" notification while the companion's Live Activity is showing. |
| `iCTRLApp/Views/SettingsView.swift` | In `body`, after `deviceSection`: `ClaudeBridgeSettingsLink()`. | The Claude Bridge row in the companion's settings. |
| `project.yml` | Under `iCTRL` → `sources`, after `- path: iCTRLKit`: source paths `ClaudeBridge/App` and `ClaudeBridge/Shared`. | Compiles the bridge screens, Shortcuts actions and Live Activity model into the companion app. |
| `project.yml` | Under `iCTRL` → `dependencies`: `- target: iCTRLBridgeWidget`. | Embeds the widget extension in the companion app. |
| `project.yml` | Under `iCTRL` → `settings` → `base`, first entry: `INFOPLIST_KEY_NSSupportsLiveActivities: YES`. | Allows the companion to show a Live Activity. |
| `project.yml` | New target `iCTRLBridgeWidget` (app-extension), placed just before `schemes:`. | The widget extension that draws the Live Activity. |
| `project.yml` | Under `iCTRLUITests` → `sources`, after `- path: iCTRLKit`: two source paths, `ClaudeBridge/Core` and `ClaudeBridge/Runner`. | Compiles the bridge into the runner. |
| `project.yml` | Under `iCTRLUITests` → `dependencies`, after `- target: iCTRL`: the static framework `ClaudeBridge/build/ClaudeBridgeTS.xcframework` with `embed: false`. | Links the Tailscale (tsnet) library into the runner. |
| `project.yml` | Under `iCTRLUITests` → `settings` → `base`, first entry: `OTHER_LDFLAGS` with `-lresolv`, CoreFoundation and Security. | System libraries the Go runtime needs. |
| `iCTRLKit/JSONRPCServer.swift` | In `init`: `self.localOnly = localOnly \|\| ClaudeBridgeGate.forceLocalOnly`. | Keeps the raw API on loopback while Funnel mode is on, whatever the remote-access setting says. |
| `Makefile` | Last two lines: `-include ClaudeBridge/bridge.mk`. | Builds the Go library before `build`; adds `make bridge-test`. |

## New files and folders (no conflict risk)

| Path | What |
|---|---|
| `CLAUDE_BRIDGE_CHANGES.md` | This file. |
| `ClaudeBridge/.gitignore` | Keeps Tailscale keys, tsnet state and secrets out of git. |
| `ClaudeBridge/scripts/sync-upstream.sh` | Fetches upstream and merges a release tag into `claude-bridge`. |
| `ClaudeBridge/scripts/hooks/pre-commit` | Blocks commits that contain a Tailscale key or a connector URL secret. |
| `ClaudeBridge/docs/UPSTREAM_SYNC.md` | The update workflow. |
| `ClaudeBridge/docs/VIABILITY.md` | Stage 1 findings: can tsnet run inside the runner. |
| `ClaudeBridge/docs/MCP_LAYER.md` | Stage 2: what the MCP layer does and how to try it. |
| `ClaudeBridge/Core/` | The bridge itself: MCP protocol, tools, allowlist guard, auth, loopback HTTP listener. Foundation and Network only. |
| `ClaudeBridge/Runner/` | Glue to iCTRL's types: RPC adapter, keychain secrets, allowlist storage, Tailscale tunnel wrapper. |
| `ClaudeBridge/App/` | Companion-app code: the Claude Bridge screen, session start/stop, Shortcuts actions. |
| `ClaudeBridge/Shared/` | Live Activity model and the Stop intent, compiled into both the companion and its widget extension. |
| `ClaudeBridge/Widget/` | The widget extension: Live Activity views and its Info.plist. |
| `ClaudeBridge/docs/SESSION.md` | Shortcuts actions, Live Activity, idle auto-off. |
| `ClaudeBridge/docs/SECRET.md` | Stage 4: the URL secret, the check, rotation, and where the secret can appear. |
| `ClaudeBridge/go/` | The Tailscale side: tsnet + Funnel reverse proxy, built as a static iOS library by `build-ios.sh`. |
| `ClaudeBridge/bridge.mk` | Makefile rules for the Go library, included from the upstream Makefile. |
| `ClaudeBridge/docs/FUNNEL.md` | Stage 3: architecture, Tailscale policy, auth key, storage. |
| `iCTRLKit/ClaudeBridgeGate.swift` | New file in an upstream folder: the "Funnel mode is on" switch, shared by the raw server and the bridge. It is here because `JSONRPCServer` is compiled into both the app and the runner. |
| `ClaudeBridge/Tests/`, `ClaudeBridge/Package.swift` | Mac unit tests (`cd ClaudeBridge && swift test`). Not part of the iOS build. |

Note: upstream already has a `Scripts/` folder. macOS file systems are
case-insensitive by default, so a top-level `scripts/` would collide with it.
Bridge scripts therefore live in `ClaudeBridge/scripts/`.
