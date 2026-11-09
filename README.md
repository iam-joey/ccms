# CCMS — Claude Code Multi-Session

One Claude Code sidebar for every Claude account on your Mac.

Sign out of account A, sign into account B, and your Claude Code sessions are
gone. Switch back and they return. Move a personal plan onto a Team plan and the
same thing happens — the list looks wiped. Nothing was deleted: the desktop app
shows you one folder at a time, and signing in with a different email points it
at a different folder.

`ccms` points them all at the same folder.

```
 ██████╗ ██████╗███╗   ███╗███████╗
██╔════╝██╔════╝████╗ ████║██╔════╝
██║     ██║     ██╔████╔██║███████╗
██║     ██║     ██║╚██╔╝██║╚════██║
╚██████╗╚██████╗██║ ╚═╝ ██║███████║
 ╚═════╝ ╚═════╝╚═╝     ╚═╝╚══════╝

  Claude Code Multi-Session v1.0
  One sidebar for every Claude account on this Mac

  Checking this Mac
  ────────────────────────────────────────────────────────
  ✓  macOS 27.0
  ✓  Claude desktop app v4.23118.0
     /Applications/Claude.app
  ✓  application support
     /Users/you/Library/Application Support/Claude
  ✓  session stores
     claude-code-sessions
     local-agent-mode-sessions
  ✓  14 folders, 3 accounts, 322 sessions on disk

  Ready
  ────────────────────────────────────────────────────────
  ccms scan   what is on this machine
  ccms share  dry-run, then --apply to do it
```

One bash script. No Python, no jq, no Homebrew, nothing to install.

---

## For the Claude desktop app on macOS only

Not the `claude` CLI — its transcripts live in `~/.claude/projects/` and are
**not** account-scoped, so they are already shared across accounts and need no
help from this. Not the web app, whose history is server-side.

Every command verifies the desktop app's files are really where it expects
before touching anything. A failing check names the exact path that was wrong
and stops, changing nothing.

## Why the sidebar empties

The desktop app writes one small pointer file per Code session:

```
~/Library/Application Support/Claude/
  claude-code-sessions/
    <accountUuid>/
      <organizationUuid>/
        local_<sessionId>.json      <- one per session in your sidebar
  local-agent-mode-sessions/
    <accountUuid>/<organizationUuid>/local_<sessionId>.json
```

The sidebar is built by listing **only** the folder for the account and
workspace you are signed into right now. A different email is a different
`<accountUuid>`, so it is a different folder, so the list is empty. The old
sessions sit on disk untouched.

(`<organizationUuid>` is the workspace — one account can belong to several, like
Slack workspaces. A personal plan has one; joining a Team adds another.)

This list is **local, not server-backed**. You can verify that the same way it
was verified here: share the folders, then open an account-A session while
signed into account B. It opens, scrollback and all.

## What ccms does

It moves every pointer file into one shared list and replaces each
`<account>/<workspace>` folder with a symlink to it:

```
claude-code-sessions/
  _pool/everything/              <- the one real folder, all sessions
  <accountA>/<workspace1> -> ../_pool/everything
  <accountA>/<workspace2> -> ../_pool/everything
  <accountB>/<workspace1> -> ../_pool/everything
```

Because every account reads and writes the same directory:

- **no copies** — one file per session, no duplicates in your sidebar
- **no drift** — nothing to re-sync, ever
- **both directions** — a session started on account B appears on A and vice
  versa, immediately
- **no background process** — the filesystem does the work

## Install

```bash
curl -fsSLO https://raw.githubusercontent.com/iam-joey/ccms/main/ccms.sh
chmod +x ccms.sh
./ccms.sh check
```

Or clone, or copy the single file anywhere. To get `ccms` as a command:

```bash
install -m 755 ccms.sh /usr/local/bin/ccms
```

## Use

```bash
ccms check             # are the desktop app's files where we expect?
ccms scan              # accounts, workspaces, session counts
ccms share             # dry-run: exactly what would change
ccms share --apply     # do it
ccms status            # are the links still intact?
ccms revert --apply    # undo: every session back where it came from
ccms watch --install   # share accounts you sign into later, automatically
```

Quit the Claude desktop app first (`--apply` refuses while it is running; pass
`--force` if you insist). `share` is idempotent — run it as often as you like.

### Accounts and workspaces you add later

Two things create a new empty folder, and both need sharing once more:

- **a new account** — signing in with another email, and
- **a new workspace on an existing account** — joining a Team, for instance.
  This one surprises people, because the email never changed.

After `share --apply` you are asked which you would rather do:

- **run it yourself** — `ccms share --apply` whenever either happens, or
- **install the watcher** — a macOS LaunchAgent that reruns the share for you.
  Event-driven: no cron, no polling, no process sitting in memory. Remove it
  with `ccms watch --uninstall`.

The watcher deliberately watches **two levels**: the store roots, where a new
account appears, and each account folder, where a new workspace appears. A new
workspace does not change the store root's mtime, so watching only the roots
would miss exactly the case above. Accounts that show up later are added to the
watch list automatically on the next share.

Nothing is installed unless you say yes. Non-interactive runs decline.

## Undo

`share --apply` writes `~/.ccms/manifest.tsv` recording every file it moved and
every folder it replaced, and keeps the original folders under `~/.ccms/backups/`.
`revert --apply` puts it all back.

Sessions you started *while* shared have no original folder to return to; revert
hands them to whichever account is signed in at the time and tells you so,
rather than leaving them stranded.

## What is and is not shared

Only the two session stores are touched. Most of what you might worry about was
never account-scoped to begin with:

| Thing | Account-scoped? | After ccms |
| --- | --- | --- |
| Claude Code sessions (sidebar) | yes | **shared** |
| Agent-mode sessions | yes | **shared** |
| Scheduled tasks (`scheduled-tasks.json`) | yes | shared, and backed up |
| SSH hosts / remote machines | no — global | already shared |
| Skills, plugins, MCP servers | no — global | already shared |
| CLI transcripts (`~/.claude/projects/`) | no — global | already shared |
| Account connectors | server-side, per account | untouched, still per account |

That last row is worth saying plainly: connectors stay tied to the account that
authorised them. Sharing the sidebar does not hand account A's Gmail to account
B.

## Limitations

- **Sharing is symmetric and total.** Every shared account sees every shared
  session. There is no "A and C but not B" — that would need copying, which
  brings back the duplicates and drift this avoids.
- **Sessions started while shared belong to no single account.** See *Undo*.
- **`scheduled-tasks.json` is per-account state**, and a folder symlink cannot
  keep it separate. It is backed up before being shared, and `share` says so.
- **Linux is untested.** The paths are macOS. Point `CCMS_SUPPORT` elsewhere at
  your own risk.
- An app update could change the store layout. `ccms check` is how you find out;
  `revert` is how you back out.

## Options and environment

| Flag | |
| --- | --- |
| `--force` | proceed even if the Claude desktop app is running |
| `--no-banner` | skip the name card |
| `--no-watch` | do not ask about the watcher after sharing |

| Variable | Default |
| --- | --- |
| `CCMS_SUPPORT` | `~/Library/Application Support/Claude` |
| `CCMS_HOME` | `~/.ccms` (undo log, backups, watcher log) |
| `CCMS_PLIST` | `~/Library/LaunchAgents/com.ccms.watch.plist` |
| `CCMS_NO_BANNER` | unset; `1` skips the name card |
| `NO_COLOR` | unset; any value turns colour off ([no-color.org](https://no-color.org)) |

The name card draws for about two seconds and is skipped automatically when
output is piped or redirected, or when running under the watcher, so logs and
scripts are never slowed down by decoration.

## Prior art, and how this differs

Two MIT-licensed tools tackled the same symptom first, and reading them is what
mapped the folder layout this relies on. Credit where it is due:

- **[restore-desktop-sessions](https://github.com/arunmauryaaa/restore-desktop-sessions)**
  — finds session files outside the current account's folder and `cp`s them in.
  One-way, one-shot, needs `jq`, undo is manual.
- **[claude-code-account-switch-recovery](https://github.com/schneidermilanistvan-hash/claude-code-account-switch-recovery)**
  — does not touch the files at all. It fires `claude://resume?session=<id>`
  deep links and lets the app re-import each session itself, which is clever and
  careful. It also handles multiple workspaces properly.

Both **recover**: you notice sessions are missing and you pull them over, in one
direction, once. The next sign-in needs doing again, and copies mean the same
session exists twice and the two can drift apart.

`ccms` **shares**. One real folder, N symlinks, no copies, both directions, and
it stays true — including for sessions created after you ran it.

## Tested on

macOS 27.0, Claude desktop v4.23118.0, 3 accounts / 7 workspaces / 322 sessions.
Share, status and revert are exercised end-to-end against a throwaway store,
including a late sign-in and sessions created while shared.

`watch --install` generates its LaunchAgent plist from the same paths but has not
been load-tested; please report anything odd.

## Licence

MIT. See [LICENSE](LICENSE).
