# CCMS — Claude Code Multi-Session

```
 ██████╗ ██████╗███╗   ███╗███████╗
██╔════╝██╔════╝████╗ ████║██╔════╝
██║     ██║     ██╔████╔██║███████╗
██║     ██║     ██║╚██╔╝██║╚════██║
╚██████╗╚██████╗██║ ╚═╝ ██║███████║
 ╚═════╝ ╚═════╝╚═╝     ╚═╝╚══════╝
```

One Claude Code sidebar for every Claude account on your Mac.

Sign in with a different account and your Claude Code chats are gone. Switch
back and they return. Nothing was deleted — the app keeps a separate folder per
account, and shows you one of them at a time.

CCMS points every account at the same folder, so they all see the same chats.
New chats show up everywhere, both ways.

One bash script. Nothing to install.

## Install

```bash
curl -fsSLO https://raw.githubusercontent.com/iam-joey/ccms/main/ccms.sh
chmod +x ccms.sh
./ccms.sh check
```

To use it as a command anywhere:

```bash
install -m 755 ccms.sh /usr/local/bin/ccms
```

## Commands

| Command | What it does |
| --- | --- |
| `ccms check` | checks the Claude app is installed and its files are where we expect |
| `ccms scan` | lists your accounts and how many chats each one sees |
| `ccms share` | shows what would change, changes nothing |
| `ccms share --apply` | does it — every account now shares one list |
| `ccms status` | checks everything is still linked |
| `ccms revert --apply` | undoes it — every chat back where it came from |
| `ccms watch --install` | keeps new accounts shared automatically |
| `ccms watch --uninstall` | removes that |

Quit the Claude app before `--apply`. Add `--force` to do it anyway.

## New accounts

Sign in with a new account, or join a Team, and the app makes a new empty
folder for it. Run `ccms share --apply` once and it joins the shared list.

`ccms watch --install` does that for you from then on. It sleeps until a folder
changes — no cron, no polling, nothing running in the background.

## Undo

`ccms share --apply` writes down everything it moved, and keeps a backup of
every folder it replaced, in `~/.ccms`. `ccms revert --apply` puts it all back.

## Notes

- macOS, and the Claude **desktop app** only. The `claude` CLI stores its
  transcripts elsewhere and already shares them across accounts.
- Every account sees every chat. You cannot share with some accounts and not
  others.
- Connectors are not touched. They stay with the account you added them to.

## Options

| | |
| --- | --- |
| `--force` | run even while the Claude app is open |
| `--no-banner` | skip the logo |
| `--no-watch` | don't ask about the watcher |
| `NO_COLOR=1` | no colours |
| `CCMS_SUPPORT` | where the Claude app keeps its files |
| `CCMS_HOME` | where CCMS keeps its backups (default `~/.ccms`) |

## Licence

MIT. See [LICENSE](LICENSE).
