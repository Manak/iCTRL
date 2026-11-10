# Keeping the fork in sync with upstream iCTRL

## How the repository is laid out

| Name | What it is | Rule |
|---|---|---|
| `origin` | Your fork, `github.com/Manak/iCTRL` | You push here. |
| `upstream` | The original, `github.com/OpenMinis/iCTRL` | Fetch only. Its push URL is set to `DISABLED`, so an accidental push fails. |
| `main` | A mirror of `upstream/main` | Never commit to it. It only ever fast-forwards. |
| `claude-bridge` | All bridge work | Long-lived. Small, focused commits. Upstream releases are merged into it. |

`main` tracks `upstream/main`, so `git status` on `main` tells you how far
behind upstream you are.

## Setting up a fresh clone

```bash
git clone git@github.com:Manak/iCTRL.git
```

```bash
cd iCTRL && git remote add upstream https://github.com/OpenMinis/iCTRL.git && git remote set-url --push upstream DISABLED
```

```bash
git fetch upstream --tags && git branch --set-upstream-to=upstream/main main && git switch claude-bridge
```

```bash
git config core.hooksPath ClaudeBridge/scripts/hooks
```

The last line turns on the pre-commit check that refuses Tailscale keys and
connector URL secrets.

## Updating to a new upstream release

```bash
ClaudeBridge/scripts/sync-upstream.sh
```

With no argument it merges the newest upstream `v*` tag. Pass a tag or ref to
choose one: `ClaudeBridge/scripts/sync-upstream.sh v1.99.0`.

The script:

1. fetches `upstream` with tags;
2. fast-forwards `main` to `upstream/main` and pushes `main` to your fork
   (it stops if `main` has diverged, which means something was committed to it
   by mistake);
3. merges the tag into `claude-bridge` with a merge commit;
4. prints the hook points that are still in the tree.

It does not push `claude-bridge`. Do that after the build and tests pass.

### If the merge conflicts

Conflicts can only happen in the upstream files listed in
[`CLAUDE_BRIDGE_CHANGES.md`](../../CLAUDE_BRIDGE_CHANGES.md). For each
conflicted file:

1. Take upstream's version of the surrounding code.
2. Re-apply the line(s) marked `CLAUDE-BRIDGE HOOK`, as described in the table.
3. `git add <file>`.

Then `git commit` to finish the merge, or `git merge --abort` to back out.

### After the merge

1. Check that the hook list matches the table:
   ```bash
   git grep -n "CLAUDE-BRIDGE HOOK" -- . ':!ClaudeBridge' ':!CLAUDE_BRIDGE_CHANGES.md'
   ```
2. Rebuild: `make ipa`.
3. Run the bridge unit tests, then the short end-to-end check (start a
   session, call one tool from Claude, stop the session).
4. Push: `git push origin claude-bridge`.

## Why merge and not rebase

`claude-bridge` is pushed to GitHub and is long-lived. Rebasing it onto each
release would rewrite its history every time, need a force-push, and replay
every bridge commit against the new upstream (so one conflict can come back
once per commit). A merge resolves each conflict once and keeps a record of
which upstream release the branch was built against.

## Files likely to conflict

Upstream changes these on most releases, so the bridge avoids editing them
where it can and keeps any edit to one marked line:

- `iCTRLKit/BuildStamp.swift` (rewritten by every build; never edit)
- `README.md`, `SKILL.md` (bridge docs live under `ClaudeBridge/docs/`)
- `iCTRLUITests/iCTRLUITests.swift`, `iCTRLKit/JSONRPCServer.swift`,
  `iCTRLApp/Views/SettingsView.swift`, `project.yml` (large and active)
