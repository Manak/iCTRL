# Stage 2: the MCP layer on localhost

Status on 2026-11-10: built, unit-tested on the Mac (52 tests), and run on an
iPhone on iOS 27.2 over a USB port forward. Results are under "Tested on the
phone" below.

## What it is

An MCP server (Streamable HTTP, stateless JSON responses) that runs inside the
iCTRL runner and listens on `127.0.0.1:8220` only. It is off by default; with
it off the runner behaves exactly like upstream.

```
POST /<secret>/mcp ─▶ BridgeHTTPServer (loopback only)
                      └▶ BridgeMCPServer   auth, then initialize / tools/list / tools/call
                         └▶ BridgeTools    argument checks, rate limit, action log
                            └▶ BridgeGuard check foreground ▶ act ▶ check again
                               └▶ iCTRL's in-process RPC dispatcher (the raw API)
```

The raw API is never proxied. Each tool builds its own raw call from validated
arguments.

## Tools

| Tool | During lockout | Notes |
|---|---|---|
| `phone_status` | works | State (`ready`, `locked_out`, `phone_locked`), battery, thermal state. Never names a non-allowlisted app. |
| `list_allowed_apps` | works | The allowlist. Read-only. |
| `go_home` | works | Returns to the home screen. The way out of lockout. |
| `screenshot` | refused | JPEG. At scale 1, pixels equal tap points. |
| `read_ui` | refused | The whole page by default: every element the app has loaded, on screen or not, with type, label, state and frame. Starts with the scroll position. `visible_only` limits it to the screen; `filter_text` is for re-checking one known element. |
| `scroll` | refused | Precise scrolling without momentum: `direction` plus `pages` (a fraction of a screen) or `points`; optional `x`,`y` to scroll one area. Reports whether it moved and the new position. |
| `scroll_to` | refused | Brings an element into view by label or identifier and returns its tap point. |
| `check_element` | refused | Reports on one element without touching it: found or not, kind and state, on screen or not, whether a tap would reach it, and how far to scroll to centre it. |
| `run_steps` | refused | Runs up to 10 actions in one call (`tap_element`, `scroll_to`, `tap`, `scroll`, `swipe`, `type_text`, `check_element`, `wait`). Stops at the first failure; each step is guarded like a separate call. |
| `tap_element` | refused | Taps an element by label or identifier wherever it is: scrolls it into view first if it is off screen, waits for the list to stop, then taps. `occurrence` picks among duplicates. |
| `tap` | refused | x, y in points. |
| `swipe` | refused | Low-level gesture (pull to refresh, swipe a row). Refuses starts within 40 pt of the top edge or 50 pt of the bottom edge (system gestures). |
| `type_text` | refused | Refused in apps marked read-only. |
| `launch_app` | refused | Allowlisted bundle ids only. |
| `open_url` | refused | Only URL schemes and link hosts that belong to an allowlisted app. |

There is no tool that changes the allowlist.

## How Claude is told to use it

The server's instructions and the tool descriptions steer towards:

- **One full `read_ui` before acting.** The default read is the whole page, so
  a series of actions can be planned from it. Filtered reads hide the context
  needed to choose the right element (a "contains" search for a dish name
  matched another dish's description), and screenshots are described as a last
  resort for pictures or for working out why something failed.
- **Acting by label** with `tap_element`, checking with `check_element`, and
  chaining with `run_steps`.

## A new action replaces the one in progress

Action calls are not queued. When a new action call arrives (`tap`,
`tap_element`, `swipe`, `scroll`, `scroll_to`, `type_text`, `launch_app`,
`open_url`, `go_home`, `run_steps`) while another is still running:

- the running call stops at its next step and returns `stopped: a newer tool
  call replaced this one…`, listing the steps it completed. What it had
  already done on the phone stands; nothing is undone;
- an action that was itself still waiting when a newer one arrived does
  nothing at all;
- the newest call then runs.

Read-only calls (`read_ui`, `screenshot`, `check_element`, `phone_status`,
`list_allowed_apps`) never stop anything and are never stopped; they wait
their turn. A step that is mid-gesture finishes that gesture first, so the
stop takes effect within a few seconds, not instantly.

The instructions tell Claude this, and to wait for an action's result before
sending the next unless it means to replace it. Note for clients that send
several tool calls at once: two actions sent together will not both run.

## Rules enforced

- **Before and after every action** the bridge reads the foreground app
  (`device_info`). Home screen, system search or an allowlisted app: proceed.
  Anything else, including an app the runner cannot name: lockout.
- **"Home" is verified, not assumed.** SpringBoard also hosts the app
  switcher, which shows other apps' screens. When SpringBoard is in front the
  bridge reads SpringBoard's own UI tree and accepts it as home only if the
  icon grid (`Home screen icons`) is there and no app-switcher element is.
- **System search is allowed like the home screen.** On iOS 27 the pull-down
  search is a separate process, "Siri AI", bundle id `com.apple.campo`. It can
  be in front, but `launch_app` will not open it and it is not in the
  editable allowlist. Note that search can show results from any app.
- **Lockout** returns only `locked: non-allowlisted app in foreground…`. No app
  name, no screen content. If an action itself caused it, the action's result
  (including a screenshot already captured) is discarded.
- **Lockout clears by itself** when the home screen or an allowlisted app is
  in front again. Each lockout is written to the runner log once.
- **Phone locked** returns `phone locked: …` and does nothing.
- **Screen content is quoted** inside a `<screen_content id="…">` block with a
  random id and a note that it is untrusted data. Raw error text is quoted the
  same way, because it can contain on-screen labels.
- **Rate limit**: bursts of 30 calls, 2 per second sustained.
- **Auth**: a 256-bit URL-path secret, compared in constant time. Any other
  request gets a plain `404 page not found`. The secret is generated on first
  start and kept in the runner's keychain. It is never logged.
- **Action log**: tool name, status and time. No arguments or content.

## Tested on the phone (iPhone, iOS 27.2)

| Check | Result |
|---|---|
| Wrong path, root path | plain `404 page not found` |
| Loopback only | A Wi-Fi port forward is refused; only USB forwarding reaches it |
| All ten tools | Work. `launch_app` opens WhatsApp; `read_ui`, `screenshot`, `tap`, `swipe`, `type_text` work in WhatsApp and in search |
| Refusals | Non-allowlisted bundle id, foreign URL, edge swipes: refused before touching the phone |
| Safari in front | Every guarded tool returns only the locked message; no app name, no image |
| App switcher in front | Locked out (after the home-screen check was added) |
| Control Centre, over the home screen or over WhatsApp | Locked out. iOS makes SpringBoard the front app while it is open, and the icon grid is not visible, so the home-screen check fails |
| Notification Centre, over the home screen or over WhatsApp | Refused as `phone locked`. iOS reports the screen as locked while that sheet is down |
| Keep-awake (first version, a bottom-edge tap) | Held a 30 s Auto-Lock for 19 minutes, but the taps hit real controls; replaced by a key event that is not yet verified (see FUNNEL.md) |
| `go_home` | About 1.9 s from Safari or WhatsApp to a verified home screen |
| Runner log | Tool name and status only; typed text and the secret do not appear |
| Guard overhead | 40 to 100 ms per call in an app; about 450 ms more on the home screen |

What the phone test changed:

- **The app switcher leaked.** iCTRL reports it as SpringBoard, so the first
  build treated it as home and returned a screenshot of other apps' previews.
  Fixed by the home-screen check above.
- **`go_home` no longer uses the bottom-edge swipe.** That gesture is fast but
  can stop in the app switcher. It now brings SpringBoard forward as an app,
  then falls back to the Home button, and stops as soon as something
  permitted is in front.
- **Search will not close.** Neither method dismisses the iOS 27 search
  screen. Since search is permitted, `go_home` reports "Search is in front"
  instead of failing.

## Known gaps

- **`go_home` from search does not reach the home screen** (see above). The
  last change, stopping early there, takes 2.3 s on the phone.
- **Typing in WhatsApp is slow**: 12 characters took 26 s inside iCTRL's own
  `type` call, and clearing with empty text timed out there. In search the
  same call took 1.3 s. Not a bridge issue, but worth tuning (`via`, `fast`).
- **No way to read the URL yet.** Showing and rotating the connector URL comes
  with Stage 4 and the companion app. Until then a development run uses
  `ICTRL_BRIDGE_DEV_SECRET`.
- **Read-only apps block typing only.** Taps on send buttons are not detected.
- **Raw API visibility is not yet forced to "this device only"** while the
  bridge runs. That hook lands with Funnel in Stage 3.

## Trying it

Unit tests:

```bash
cd ClaudeBridge && swift test
```

On a phone (development run from Xcode): add two environment variables to the
iCTRL scheme's Test action, then run the test as usual.

| Variable | Value |
|---|---|
| `ICTRL_BRIDGE` | `1` |
| `ICTRL_BRIDGE_DEV_SECRET` | any string of 32 or more URL-safe characters |

The endpoint is then `http://127.0.0.1:8220/<secret>/mcp` on the phone. From
the Mac, forward the port over USB (`iproxy 18220:8220`) and call
`http://127.0.0.1:18220/<secret>/mcp`. The same run can be started from the
command line with `xcodebuild test-without-building`, passing the variables
with a `TEST_RUNNER_` prefix.

## Finding markers on a new iOS version

Run with `ICTRL_BRIDGE_DIAG=1`. Every two seconds the runner logs which app is
in front, the lock flag and the element ids in SpringBoard's visible tree
(identifiers only, never labels), whenever they change. Open each surface for
a few seconds and read the log. On iOS 27.2 that showed:

| Screen | Front app | Lock flag | Telling ids |
|---|---|---|---|
| Home screen | SpringBoard | false | `Home screen icons` |
| App switcher | SpringBoard | false | `AppSwitcherContentView`, `SBSwitcherWindow:Main` |
| Control Centre (anywhere) | SpringBoard | false | `cc-root-folder-view`, no icon grid |
| Notification Centre (anywhere) | SpringBoard | **true** | `NotificationShortLookView` |
| Pull-down search | `com.apple.campo` | false | |
| An app | that app | false | |

## The allowlist

Edited in the companion app: Claude Bridge → Allowed apps. The screen lists
the installed apps, each with a switch; an allowed app also gets a read-only
switch. The list is stored in the runner and read fresh on every tool call,
so a change applies immediately. It is changed through the companion's
`claude_bridge` method (`set_allowlist`), never through MCP.

**It starts empty.** Until an app is switched on, Claude can only see the home
screen and search. No app is special in the code: WhatsApp is one row like any
other.

### Where the list of installed apps comes from

iOS has no public way to list installed apps and refuses the usual private
ones. Measured on iOS 27.2:

| Route | Apps found |
|---|---|
| `LSApplicationWorkspace` (all applications) | 0 |
| `LSApplicationRecord` enumeration | 0 |
| Apps that contain an extension (via the plug-in list) | 198 |
| Apps this runner has opened before | 11 |

The screen shows the last two combined. Most apps include at least one
extension, but one that does not, and has never been opened through iCTRL,
will be missing; it can be added by bundle id at the bottom of the screen.

### Rules

- Never allowed, and ignored even if stored: Settings, the App Store, Wallet,
  Shortcuts, TestFlight, SpringBoard, and iCTRL's own companion and runner.
- The home screen and system search are always permitted and are not part of
  the list.
- `open_url` only works for apps whose link formats are known
  (`BridgeKnownLinks`: currently WhatsApp, Telegram and Signal) and only when
  that app is on the list. Other apps can still be opened with `launch_app`.
- Read-only blocks typing. Taps on send buttons are not detected.

Not yet tried on a phone.

## Elements, scrolling and coordinates: what real apps needed

Found while driving a food-ordering menu in Grab on iOS 27.2, and fixed in
`BridgeUITree` and `BridgeTools`:

- **Apps that draw at their own size.** Grab draws at 375 x 667 and iOS scales
  it onto the 466 x 678 screen, at the top-left. Its frames are then not tap
  points. `read_ui` converts every frame to screen points and says so.
- **Bogus frames in off-screen rows.** Children of a row that is off screen all
  reported the list's origin as their frame, so iCTRL's own
  `scroll_to_element` decided an item four screens down was already in view.
  The bridge does not use it. It parses the tree, takes the row's own frame
  when a child's frame falls outside its row, and scrolls with exact slow
  drags inside the scrolling view until the element's centre is showing.
- **Taps on a gliding list are swallowed.** After a scroll the bridge re-reads
  until two readings of the element's position agree, then taps.
- **The child limit hid rows.** `page_source` applies `max_children` before
  its on-screen filter, so at 50 the rows past the 50th never appeared, even
  when they were the ones on screen. `read_ui` now asks for 400.

Verified on the phone: `tap_element` selected items one and four screens down
the list, and the basket total changed to match.

### Getting to a far-away element

`scroll_to` and `tap_element` reach an element in this order:

1. **Ask the app to jump.** The runner performs the accessibility "scroll to
   visible" action on the element (`ClaudeBridgeJump`). The app scrolls itself
   straight there, however far it is. On a menu 38 screens long this took one
   step; the element lookup costs about 3.5 s.
2. **Bring it well inside the view.** The jump tends to leave the element at
   the very edge, under a navigation bar or sticky header, where a tap misses.
   Once the list is being moved, the element must clear 18% of the area at the
   top and bottom; one exact slow drag does that.
3. **Fall back to gestures** if the app will not jump: one call to the
   device's paging for the long stretch, then the exact drag.

### What the tree says about each element

iOS has no "clickable" flag, so `read_ui` adds three words, placed just before
an element's frame:

| Word | Meaning | Where it comes from |
|---|---|---|
| `tappable` | Probably responds to a tap | A hint: the element's type (Button, Link, Cell, Switch, text fields, …) or a control word in its identifier (`…_button`, `…_tab`, `cta`, `checkbox`, …). Misses custom controls; can flag something inert. Never given to a disabled element |
| `disabled` | Greyed out by the app | The accessibility snapshot's enabled flag (hook in `ForegroundApp.m`, code in `ClaudeBridgeTreeState.m`) |
| `selected` | The active one of a set | The snapshot's selected flag |

`check_element` answers the per-element questions. "A tap would reach it" is
XCTest's own hittable test; on the phone it said yes for a row sitting under
the menu's header, where a tap had missed, so treat a "yes" at the very edge
with suspicion. "Scroll needed" is worked out from the row's real position and
is what to rely on.

After `scroll_to` or `tap_element` has moved a list, the bridge runs the same
reachability test before tapping. If the element is covered where it stopped,
it is put in the exact middle and tested again; if it is still covered,
`tap_element` reports that instead of tapping.

Cost: each lookup of an element by label takes about 3.5 s on a large screen
(Grab's menu). A `tap_element` that has to scroll now does up to three of
them (jump, reachability, tap), so it takes around 20 s there. `run_steps`
saves the round trips between steps, not this time.

### Pressing an element with no touch at all: tried, not working

The idea: activate the element itself through accessibility (what VoiceOver's
double-tap does), so no coordinates and no scrolling are needed. XCTest can
send accessibility actions to an element (`-[XCAXClient_iOS
performAction:onElement:value:error:]` with an `XCUIAccessibilityAction`), and
that is how the jump above works (action 2003, scroll to visible).

Sending the press action (2010) to a menu item's label in Grab was refused
with `kAXErrorFailure`, and the enclosing row gave no accessibility handle to
try. Not established: whether 2010 is the right action on iOS 27, whether
buttons accept it where labels do not, or whether iOS lets a test runner
press at all. So `tap_element` still scrolls the element into view and taps
where it is. If this is revisited, it would also be the way to act in
large-display mode, where touches do nothing.

`contains` matching finds the first element whose label contains the text,
which can be a description rather than a title. Searching for "Veggie Delite"
opened a meal whose description mentioned it; the exact label
("Veggie Delite™ 6 Inch") found the right row.

`scroll` reports whether it moved from the measured position, because the
device's own "moved" flag reads false after a multi-screen scroll.

Not handled: horizontal scrolling to an element, and lists that only build
rows as you scroll are searched by paging down only (not up).

## Large-display (windowed) mode: what works and what does not

The phone this is developed on has a second, larger display mode. In it iOS
lays the screen out at 669 x 951 points while the runner works at 466 x 678,
iPhone-only apps are shown in a window, and the home screen is drawn by the
system search process ("Siri AI", `com.apple.campo`, the window host), not by
SpringBoard. Found while trying to search Carousell:

| Area | State |
|---|---|
| Which app is in front | **Fixed.** iCTRL named the wrong app (Taobao while Carousell was on screen): it trusts an app's "foreground" state, which lags, and the frontmost process is the window host. The bridge now decides itself (`ClaudeBridgeScreenProbe`, `BridgeForegroundDecision`): a process id must agree, and in windowed mode exactly one known app may claim the foreground. iCTRL's own resolver also got a process-id check (hook in `ActionHandler.swift`). |
| `read_ui` | **Fixed.** It names the app explicitly (the raw API otherwise read the wrong app and timed out after 15 s), and converts frames using the window's real position, read from SpringBoard's tree (`BridgeWindowLocator`). |
| `launch_app`, `screenshot` | Work. |
| `tap`, `tap_element`, `type_text`, `scroll`, `swipe` | **Do not work in this mode.** Synthesized touches take about 5.4 s and have no effect, in either coordinate space. Likely cause, not confirmed: XCTest aims events at the default display, and the content is on the other one (`XCSynthesizedEventRecord` has an `initWithName:displayID:` that upstream does not use). |
| `go_home` | Does not reach a classic home screen; the host's own screen (icons and a search bar) is treated like search, so tools are not locked out there. |

Residual risk in windowed mode: the "exactly one app claims the foreground"
check can only see apps the phone lets the runner list (those with an
extension, or opened through iCTRL before). An app outside that list, shown in
a window while nothing else claims the foreground, would be taken for the
host's own screen.

Tried and discarded: asking iOS which process owns the element at a screen
point. For a windowed app it answers "SpringBoard".

Diagnostics for this work are behind environment variables:
`ICTRL_BRIDGE_DIAG=1` (front app, lock flag, SpringBoard ids, the foreground
decision's inputs), `ICTRL_BRIDGE_DIAG_APPS=1` (per-app state and pid),
`ICTRL_BRIDGE_DIAG_TREES=1` (candidate window frames in SpringBoard's tree).
