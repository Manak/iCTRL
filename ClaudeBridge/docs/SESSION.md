# Sessions: Shortcuts actions, Live Activity, idle auto-off

Status on 2026-11-10: built, unit-tested where it can be (idle timer), both
apps and the widget extension compile, sign and install. **The Shortcuts
actions, the Live Activity and the auto-off have not yet been exercised on a
phone.**

## What a session is

A session is the runner running in Claude via Funnel mode: the public address
is up, the bridge answers, keep-awake is on. It starts when the owner starts
it and ends when the owner stops it or Claude has been quiet for 30 minutes.
Nothing can start a session remotely: once the runner is off there is nothing
on the phone listening.

## Shortcuts actions

They appear in the Shortcuts app under iCTRL, and work from Siri, the Action
Button and personal automations.

| Action | Opens the app? | What it does | Returns |
|---|---|---|---|
| Start Session | Yes, briefly | Launches the runner if needed, switches Claude via Funnel on, waits for the address to go live, shows the Live Activity | `live`, or a reason: `ddi_not_mounted`, `not_paired`, `runner_not_responding`, `needs_login`, … plus a sentence. Never the secret |
| Stop Session | No | Stops the address, the bridge, the raw API and the runner; removes the Live Activity | `stopped` or a reason |
| Remount Developer Disk Image | No | Mounts the image (needed after every reboot) | `mounted` or the failure reason |

Start has to bring iCTRL to the front because iOS only lets a foreground app
launch the runner. The runner then shows for a moment and hands back.

Requirements: the companion must have been connected to the runner once
(Claude Bridge → Connect to runner), and for Remount the usual set-up
(LocalDevVPN connected, Wi-Fi, pairing file and image present).

Example automation: "When Claude is opened → Start Session → Open App: Claude".

## Idle auto-off

The runner counts every authentic MCP request as activity. After 30 minutes
without one it ends the session through iCTRL's own stop path: the run loop
exits, the bridge and the tsnet node close, and the runner process ends.
Keep-awake pulses and the companion's status checks do not count as activity.

Change the limit with the runner default `claudeBridge.idleMinutes` (0 means
never). There is no screen for it yet.

## Live Activity

Shown by the companion app while a session is live, on the Lock Screen and in
the Dynamic Island: that the bridge is live, how long it has been running, the
time it will switch itself off if Claude stays quiet, and a **Stop** button.
Stop runs the same action as "Stop Session".

Once the Live Activity is showing, the companion tells the runner, and the
runner withholds its own "iCTRL Server Ready" notification for that session.
Pairing requests and "Server Stopped" still come as notifications, because
only the runner can raise them.

### What it cannot do

iOS lets only the companion (or a push server) update a Live Activity, and
the companion is suspended in the background. So:

- It does not show what Claude is doing, or a lockout, in real time.
- The auto-off time shown is as of the last time the companion was awake. If
  Claude makes more calls, the real time moves later.
- If the session ends by itself, the activity is not removed at that moment.
  It marks itself "check status" one minute after the auto-off time it knew
  about, and is removed or refreshed the next time iCTRL comes to the front
  or you press Stop.
- It only appears if the session was started through the companion (the Start
  button, the Start Session action, or opening the Claude Bridge screen). A
  session started with a bare `ictrl://start` link gets the runner's
  notification instead, until iCTRL is next opened.

## Not built

- Opening and closing the raw local API on demand. It still runs for the whole
  session, loopback only.
- A Resume or Go Home button on the Live Activity.
- Holding back iOS's "Automation Running" overlay until Claude's first call.
