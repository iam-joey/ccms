#!/bin/bash
# ccpool - make every Claude account on this Mac share one Claude Code sidebar.
#
# FOR THE CLAUDE DESKTOP APP ON macOS ONLY. Not the `claude` CLI (its
# transcripts live in ~/.claude/projects and are not account-scoped, so they
# are already shared) and not the web app.
#
# The desktop app stores each Code session as a small pointer file under
#     <store>/<accountUuid>/<orgUuid>/local_<id>.json
# and builds the sidebar by listing ONLY the folder of the account + workspace
# you are signed into. Switch account - or move a personal plan to Team - and
# the list looks empty, although every session is still on disk.
#
# ccpool moves those pointer files into one shared pool and replaces each
# <account>/<workspace> folder with a symlink to it. Every pooled account then
# reads and writes the same list: no copies, no drift, both directions, and new
# sessions show up everywhere at once.
#
# Nothing to install: bash, mv, ln and plutil, all shipped with macOS.
#
#   ccpool check            is this machine set up the way ccpool expects?
#   ccpool scan             accounts, workspaces and session counts
#   ccpool pool             dry-run: what would be pooled
#   ccpool pool --apply     do it (writes a manifest so revert works)
#   ccpool status           are the links still intact?
#   ccpool revert --apply   undo, putting every session back where it came from
#   ccpool watch --install  auto-pool accounts you sign into later
#
# MIT licence.

set -u

VERSION="1.0"
POOL_DIRNAME="_pool"
POOL_NAME="everything"
AGENT_LABEL="com.ccpool.watch"

# The two per-account+workspace session stores the desktop app keeps.
STORES="claude-code-sessions local-agent-mode-sessions"

# Per-account state that is not a session. A folder symlink necessarily shares
# these too, so we back them up and say so.
NON_SESSION="scheduled-tasks.json"

SUPPORT="${CCPOOL_SUPPORT:-$HOME/Library/Application Support/Claude}"
STATE="${CCPOOL_HOME:-$HOME/.ccpool}"
MANIFEST="$STATE/manifest.tsv"
BACKUPS="$STATE/backups"
PLIST="${CCPOOL_PLIST:-$HOME/Library/LaunchAgents/$AGENT_LABEL.plist}"

TAB=$(printf '\t')
PREFLIGHT_OK=1

die() { printf '%s\n' "$*" >&2; exit 2; }

# ---------------------------------------------------------------- helpers

is_uuid() {
  [ ${#1} -eq 36 ] || return 1
  case "$1" in
    ????????-????-????-????-????????????) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!0-9a-fA-F-]*) return 1 ;;
  esac
  return 0
}

# Absolute, symlink-resolved path of a directory, or "" if it does not resolve.
resolve() { ( cd "$1" 2>/dev/null && pwd -P ) || true; }

count_sessions() {
  local n=0 f
  for f in "$1"/local_*.json; do [ -e "$f" ] && n=$((n + 1)); done
  printf '%s' "$n"
}

short() { printf '%s' "${1:0:8}"; }

# plutil reads JSON as happily as it reads plists, and ships with macOS - so no
# jq, no python. Missing key or missing file just yields "".
jget() { plutil -extract "$2" raw -o - "$1" 2>/dev/null | head -1; }

# Remember uuid -> email for whichever account is signed in right now, so later
# runs can label folders even while signed into a different account.
learn_accounts() {
  local cli="$HOME/.claude.json" uuid email org orgname
  mkdir -p "$STATE"
  touch "$STATE/accounts.tsv"
  [ -f "$cli" ] || return 0
  uuid=$(jget "$cli" oauthAccount.accountUuid)
  [ -n "$uuid" ] || return 0
  email=$(jget "$cli" oauthAccount.emailAddress)
  org=$(jget "$cli" oauthAccount.organizationUuid)
  orgname=$(jget "$cli" oauthAccount.organizationName)
  _remember "$uuid" "$email"
  [ -n "$org" ] && _remember "$org" "$orgname"
  return 0
}

_remember() {
  local id="$1" name="$2"
  [ -n "$id" ] && [ -n "$name" ] || return 0
  grep -q "^$id$TAB" "$STATE/accounts.tsv" 2>/dev/null && return 0
  printf '%s\t%s\n' "$id" "$name" >>"$STATE/accounts.tsv"
}

name_of() {
  local id="$1" hit
  hit=$(grep "^$id$TAB" "$STATE/accounts.tsv" 2>/dev/null | head -1)
  if [ -n "$hit" ]; then printf '%s' "${hit#*$TAB}"; else printf '%s' "$(short "$id")"; fi
}

label_for() { printf '%s / %s' "$(name_of "$1")" "$(name_of "$2")"; }

app_bundle() {
  local p
  for p in /Applications/Claude.app "$HOME/Applications/Claude.app"; do
    [ -d "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

app_running() {
  pgrep -f 'Claude.app/Contents/MacOS/Claude' >/dev/null 2>&1
}

ask() {
  local reply
  [ -t 0 ] || return 1                      # launchd, pipes: take the default
  printf '%s [y/N] ' "$1"
  read -r reply || { printf '\n'; return 1; }
  case $(printf '%s' "$reply" | tr 'A-Z' 'a-z') in y | yes) return 0 ;; esac
  return 1
}

# Every <account>/<workspace> folder, one TSV row each:
#   store <TAB> account <TAB> workspace <TAB> kind <TAB> path
# kind: folder (a real directory, poolable) | linked (already pooled) |
#       relink (a link elsewhere inside the store) | foreign (leave alone)
each_folder() {
  local store store_dir acct_dir org_dir acct org pool_real store_real real kind
  for store in $STORES; do
    store_dir="$SUPPORT/$store"
    [ -d "$store_dir" ] || continue
    store_real=$(resolve "$store_dir")
    pool_real=$(resolve "$store_dir/$POOL_DIRNAME/$POOL_NAME")
    for acct_dir in "$store_dir"/*; do
      [ -d "$acct_dir" ] || continue
      acct=${acct_dir##*/}
      is_uuid "$acct" || continue
      for org_dir in "$acct_dir"/*; do
        [ -e "$org_dir" ] || [ -L "$org_dir" ] || continue
        org=${org_dir##*/}
        is_uuid "$org" || continue
        if [ -L "$org_dir" ]; then
          real=$(resolve "$org_dir")
          if [ -n "$pool_real" ] && [ "$real" = "$pool_real" ]; then
            kind=linked
          elif [ -n "$real" ] && [ -n "$store_real" ] && \
               [ "${real#$store_real/}" != "$real" ]; then
            kind=relink
          else
            kind=foreign
          fi
        elif [ -d "$org_dir" ]; then
          kind=folder
        else
          continue
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$store" "$acct" "$org" "$kind" "$org_dir"
      done
    done
  done
}

# Resolved, de-duplicated directories behind those folders, read from stdin.
# Pooled folders all point at one pool, so this collapses them to one entry.
unique_dirs() {
  local _s _a _o _k path
  while IFS="$TAB" read -r _s _a _o _k path; do
    [ -n "${path:-}" ] && resolve "$path"
  done | sort -u
}

# --------------------------------------------------------------- preflight

# Confirms this really is a Claude desktop install whose layout we understand.
# Prints one line per check, naming the exact path, so a failure says which
# thing was wrong instead of just "unsupported". Sets PREFLIGHT_OK.
preflight() {
  local app ver stores store found rows accts total
  PREFLIGHT_OK=1

  if [ "$(uname -s)" = Darwin ]; then
    printf '  ok   macOS %s\n' "$(sw_vers -productVersion 2>/dev/null)"
  else
    printf '  FAIL this is %s, not macOS\n' "$(uname -s)"
    printf '       ccpool only knows the macOS desktop layout. Point CCPOOL_SUPPORT\n'
    printf '       at your store if you know where it is, at your own risk.\n'
    PREFLIGHT_OK=0
  fi

  if app=$(app_bundle); then
    ver=$(jget "$app/Contents/Info.plist" CFBundleShortVersionString)
    printf '  ok   Claude desktop app: %s%s\n' "$app" "${ver:+ v$ver}"
  else
    printf '  warn Claude.app not in /Applications or ~/Applications\n'
    printf '       Checking the files anyway - a moved app is fine.\n'
  fi

  if [ -d "$SUPPORT" ]; then
    printf '  ok   app support: %s\n' "$SUPPORT"
  else
    printf '  FAIL no Claude support directory at %s\n' "$SUPPORT"
    printf '       Is this the desktop app (claude.ai/download)? The `claude` CLI\n'
    printf '       alone never creates it. Sign into the app once, or set\n'
    printf '       CCPOOL_SUPPORT to the directory.\n'
    PREFLIGHT_OK=0
    return 0
  fi

  found=""
  for store in $STORES; do
    [ -d "$SUPPORT/$store" ] && found="$found $store"
  done
  if [ -n "$found" ]; then
    printf '  ok   session store(s):%s\n' "$found"
  else
    printf '  FAIL none of these under the support dir: %s\n' "$STORES"
    printf '       Open one Claude Code session in the desktop app, quit it, then\n'
    printf '       run this again.\n'
    PREFLIGHT_OK=0
    return 0
  fi

  rows=$(each_folder)
  if [ -n "$rows" ]; then
    accts=$(printf '%s\n' "$rows" | cut -f2 | sort -u | wc -l | tr -d ' ')
    # Pooled folders all resolve to the same directory, so count it once.
    total=0
    while IFS= read -r real; do
      [ -n "$real" ] || continue
      total=$((total + $(count_sessions "$real")))
    done <<EOF
$(printf '%s\n' "$rows" | unique_dirs)
EOF
    printf '  ok   %s folder(s), %s account(s), %s session(s) on disk\n' \
      "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" "$accts" "$total"
  else
    printf '  FAIL the stores exist but hold no <account>/<workspace> folders\n'
    printf '       Nothing to pool yet. Open a Code session in the app first.\n'
    PREFLIGHT_OK=0
  fi
  return 0
}

# Quiet unless it fails. Redirect rather than $(...): a subshell would lose
# PREFLIGHT_OK.
require_preflight() {
  local tmp
  tmp="${TMPDIR:-/tmp}/ccpool.$$"
  preflight >"$tmp" 2>&1
  if [ "$PREFLIGHT_OK" != 1 ]; then
    printf 'ccpool works on the Claude DESKTOP app for macOS. This machine:\n\n' >&2
    cat "$tmp" >&2
    printf '\nStopping - nothing was changed.\n' >&2
    rm -f "$tmp"
    exit 2
  fi
  rm -f "$tmp"
}

# ---------------------------------------------------------------- commands

cmd_check() {
  learn_accounts
  printf 'ccpool %s - Claude desktop app, macOS\n\n' "$VERSION"
  preflight
  if [ "$PREFLIGHT_OK" = 1 ]; then
    printf '  ok   watcher installed: %s\n' "$([ -f "$PLIST" ] && echo yes || echo no)"
    printf '\nReady. `ccpool scan` lists it, `ccpool pool` shows what would change.\n'
    return 0
  fi
  return 2
}

cmd_scan() {
  require_preflight
  learn_accounts
  local store last="" n
  printf 'store root: %s\n' "$SUPPORT"
  while IFS="$TAB" read -r store acct org kind path; do
    [ -n "${store:-}" ] || continue
    if [ "$store" != "$last" ]; then printf '\n[%s]\n' "$store"; last=$store; fi
    n=$(count_sessions "$path")
    printf '  %-44s %4s sessions  %s\n' "$(label_for "$acct" "$org")" "$n" "$kind"
  done <<EOF
$(each_folder)
EOF
  printf '\nlinked = already pooled, folder = not pooled yet.\n'
}

cmd_pool() {
  local apply=0 force=0 nowatch=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1 ;;
      --force) force=1 ;;
      --no-watch) nowatch=1 ;;
      *) die "pool: unknown option $1" ;;
    esac
    shift
  done

  preflight
  printf '\n'
  [ "$PREFLIGHT_OK" = 1 ] || { printf 'Stopping - nothing was changed.\n' >&2; exit 2; }
  learn_accounts

  local rows todo=0 store acct org kind path pool_dir n f extras
  rows=$(each_folder)

  # Report first, so a dry-run and an --apply show the same thing.
  while IFS="$TAB" read -r store acct org kind path; do
    [ -n "${store:-}" ] || continue
    case "$kind" in
      linked) continue ;;
      foreign)
        printf 'warning: %s/%s is a symlink outside the store; left alone\n' \
          "$(short "$acct")" "$(short "$org")"
        continue ;;
    esac
    todo=$((todo + 1))
  done <<EOF
$rows
EOF

  if [ "$todo" -eq 0 ]; then
    printf 'nothing to do - every folder is already pooled.\n'
    return 0
  fi

  printf '%s %s folder(s):\n\n' "$([ "$apply" = 1 ] && echo Pooling || echo 'Would pool')" "$todo"
  while IFS="$TAB" read -r store acct org kind path; do
    [ -n "${store:-}" ] || continue
    case "$kind" in linked | foreign) continue ;; esac
    printf '  [%s] %s\n' "$store" "$(label_for "$acct" "$org")"
    if [ "$kind" = relink ]; then
      printf '      repoint existing link -> %s/%s\n' "$POOL_DIRNAME" "$POOL_NAME"
    else
      printf '      %s sessions -> %s/%s\n' "$(count_sessions "$path")" "$POOL_DIRNAME" "$POOL_NAME"
      extras=""
      for f in $NON_SESSION; do [ -f "$path/$f" ] && extras="$extras $f"; done
      [ -n "$extras" ] && printf '      shares:%s\n' "$extras"
    fi
  done <<EOF
$rows
EOF

  if [ "$apply" != 1 ]; then
    printf '\nDRY-RUN. Re-run with --apply to do it.\n'
    return 0
  fi

  if app_running && [ "$force" != 1 ]; then
    printf '\nThe Claude desktop app is running. Quit it (Cmd+Q) first, or pass --force.\n' >&2
    exit 1
  fi

  mkdir -p "$STATE" "$BACKUPS"
  touch "$MANIFEST"
  printf '\n'

  while IFS="$TAB" read -r store acct org kind path; do
    [ -n "${store:-}" ] || continue
    case "$kind" in linked | foreign) continue ;; esac

    pool_dir="$SUPPORT/$store/$POOL_DIRNAME/$POOL_NAME"
    mkdir -p "$pool_dir"

    if [ "$kind" = relink ]; then
      rm -f "$path"
      ln -s "../$POOL_DIRNAME/$POOL_NAME" "$path"
      printf 'link\t%s\t%s\t%s\t%s\t\n' "$store" "$acct" "$org" "$path" >>"$MANIFEST"
      printf 'repointed [%s] %s\n' "$store" "$(label_for "$acct" "$org")"
      continue
    fi

    for f in "$path"/local_*.json; do
      [ -e "$f" ] || continue
      if [ -e "$pool_dir/${f##*/}" ]; then continue; fi   # same uuid, same session
      mv "$f" "$pool_dir/${f##*/}"
      printf 'move\t%s\t%s\t%s\t%s\t%s\n' \
        "$store" "$acct" "$org" "${f##*/}" "$pool_dir" >>"$MANIFEST"
    done

    # Per-account files cannot survive a folder symlink; keep a copy either way.
    for f in $NON_SESSION; do
      [ -f "$path/$f" ] || continue
      mkdir -p "$BACKUPS/$store/$acct/$org"
      cp -p "$path/$f" "$BACKUPS/$store/$acct/$org/$f"
      [ -e "$pool_dir/$f" ] || cp -p "$path/$f" "$pool_dir/$f"
    done

    mkdir -p "$BACKUPS/$store/$acct"
    mv "$path" "$BACKUPS/$store/$acct/$org.folder"
    ln -s "../$POOL_DIRNAME/$POOL_NAME" "$path"
    printf 'link\t%s\t%s\t%s\t%s\t%s\n' \
      "$store" "$acct" "$org" "$path" "$BACKUPS/$store/$acct/$org.folder" >>"$MANIFEST"
    printf 'pooled    [%s] %s\n' "$store" "$(label_for "$acct" "$org")"
  done <<EOF
$rows
EOF

  printf '\nDone. Manifest: %s\n' "$MANIFEST"
  printf 'Reopen the Claude desktop app; every pooled account now shows the same list.\n'
  [ "$nowatch" = 1 ] || offer_watcher
  return 0
}

offer_watcher() {
  [ -f "$PLIST" ] && return 0
  cat <<'EOT'

One thing this does NOT cover: an account you sign into LATER. The app gives it
a brand-new empty folder, which has to be pooled once more.

  * no   -> run `ccpool pool --apply` yourself after each new sign-in
  * yes  -> a macOS LaunchAgent does it for you. It watches the two store
            folders and only wakes when one of them changes: no cron, no
            polling, no process sitting in memory. Remove it any time with
            `ccpool watch --uninstall`.
EOT
  printf '\n'
  if ask "Install the watcher?"; then
    cmd_watch --install
  else
    printf 'Skipped. `ccpool watch --install` sets it up later.\n'
  fi
}

cmd_status() {
  require_preflight
  learn_accounts
  local store acct org kind path bad=0 pooled=0 n
  while IFS="$TAB" read -r store acct org kind path; do
    [ -n "${store:-}" ] || continue
    case "$kind" in
      linked) pooled=$((pooled + 1)) ;;
      folder)
        printf 'not pooled: [%s] %s\n' "$store" "$(label_for "$acct" "$org")"
        bad=$((bad + 1)) ;;
      *)
        printf 'odd link:   [%s] %s (%s)\n' "$store" "$(label_for "$acct" "$org")" "$kind"
        bad=$((bad + 1)) ;;
    esac
  done <<EOF
$(each_folder)
EOF
  for store in $STORES; do
    [ -d "$SUPPORT/$store/$POOL_DIRNAME/$POOL_NAME" ] || continue
    n=$(count_sessions "$SUPPORT/$store/$POOL_DIRNAME/$POOL_NAME")
    printf 'pool: %-26s %s sessions\n' "$store" "$n"
  done
  printf '%s linked folder(s)\n' "$pooled"
  if [ "$bad" -eq 0 ]; then
    printf 'all good.\n'
    return 0
  fi
  printf '\n%s folder(s) need attention - run `ccpool pool --apply`.\n' "$bad"
  return 1
}

cmd_revert() {
  local apply=0 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1 ;;
      --force) force=1 ;;
      *) die "revert: unknown option $1" ;;
    esac
    shift
  done

  [ -f "$MANIFEST" ] || die "no manifest at $MANIFEST - nothing to revert."

  local moves links
  moves=$(grep -c '^move'"$TAB" "$MANIFEST" 2>/dev/null | tr -d ' ')
  links=$(grep -c '^link'"$TAB" "$MANIFEST" 2>/dev/null | tr -d ' ')
  printf '%s %s session file(s) and %s folder(s) from %s\n' \
    "$([ "$apply" = 1 ] && echo Restoring || echo 'Would restore')" \
    "$moves" "$links" "$MANIFEST"

  if [ "$apply" != 1 ]; then
    printf '\nDRY-RUN. Re-run with --apply to do it.\n'
    return 0
  fi
  if app_running && [ "$force" != 1 ]; then
    printf '\nQuit the Claude desktop app first, or pass --force.\n' >&2
    exit 1
  fi

  # Links last-in first-out: put each folder back, then the files inside it.
  local what store acct org a b
  while IFS="$TAB" read -r what store acct org a b; do
    [ "$what" = link ] || continue
    [ -L "$a" ] && rm -f "$a"
    if [ -n "${b:-}" ] && [ -d "$b" ]; then
      mkdir -p "$(dirname "$a")"
      mv "$b" "$a"
    else
      mkdir -p "$a"
    fi
  done <"$MANIFEST"

  while IFS="$TAB" read -r what store acct org a b; do
    [ "$what" = move ] || continue
    [ -e "$b/$a" ] || continue
    mkdir -p "$SUPPORT/$store/$acct/$org"
    mv "$b/$a" "$SUPPORT/$store/$acct/$org/$a"
  done <"$MANIFEST"

  # Sessions started WHILE pooled have no manifest row of their own. Left in
  # the pool they would disappear from every sidebar, so hand them to the
  # account signed in right now (or the first folder we restored) and say so.
  local cur pool f left w s p dest
  cur=$(jget "$SUPPORT/config.json" lastKnownAccountUuid)
  for store in $STORES; do
    pool="$SUPPORT/$store/$POOL_DIRNAME/$POOL_NAME"
    [ -d "$pool" ] || continue
    for f in $NON_SESSION; do rm -f "$pool/$f"; done   # our copy; originals are back

    left=0
    for f in "$pool"/local_*.json; do [ -e "$f" ] && left=$((left + 1)); done
    if [ "$left" -gt 0 ]; then
      dest=""
      while IFS="$TAB" read -r w s acct org p b; do
        [ "$w" = link ] && [ "$s" = "$store" ] && [ -d "$p" ] || continue
        if [ -n "$cur" ] && [ "$acct" = "$cur" ]; then dest=$p; break; fi
        [ -n "$dest" ] || dest=$p
      done <"$MANIFEST"
      if [ -n "$dest" ]; then
        for f in "$pool"/local_*.json; do
          [ -e "$f" ] && mv "$f" "$dest/${f##*/}"
        done
        printf '%s session(s) started while pooled had no home to return to;\n' "$left"
        printf 'moved them to %s\n' "$dest"
      else
        printf 'warning: %s session(s) left in %s - no folder to return them to.\n' \
          "$left" "$pool" >&2
      fi
    fi

    rmdir "$pool" 2>/dev/null
    rmdir "$SUPPORT/$store/$POOL_DIRNAME" 2>/dev/null
  done

  mv "$MANIFEST" "$MANIFEST.reverted"
  printf 'Reverted. Backups are still in %s if you need them.\n' "$BACKUPS"
}

cmd_watch() {
  local mode="${1:-}" me watched store
  case "$mode" in
    --uninstall)
      launchctl unload "$PLIST" 2>/dev/null
      rm -f "$PLIST"
      printf 'watcher removed.\n'
      return 0 ;;
    --install) ;;
    "") printf 'installed: %s\n' "$([ -f "$PLIST" ] && echo yes || echo no)"; return 0 ;;
    *) die "watch: unknown option $mode" ;;
  esac

  me=$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
  watched=""
  for store in $STORES; do
    [ -d "$SUPPORT/$store" ] && \
      watched="$watched$(printf '\n    <string>%s</string>' "$SUPPORT/$store")"
  done
  [ -n "$watched" ] || die "no store to watch."

  mkdir -p "$(dirname "$PLIST")" "$STATE"
  cat >"$PLIST" <<EOT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$me</string>
    <string>pool</string>
    <string>--apply</string>
    <string>--force</string>
    <string>--no-watch</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CCPOOL_SUPPORT</key><string>$SUPPORT</string>
    <key>CCPOOL_HOME</key><string>$STATE</string>
  </dict>
  <key>WatchPaths</key>
  <array>$watched
  </array>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$STATE/watch.log</string>
  <key>StandardErrorPath</key><string>$STATE/watch.log</string>
</dict>
</plist>
EOT
  launchctl unload "$PLIST" 2>/dev/null
  launchctl load "$PLIST" || die "launchctl could not load $PLIST"
  printf 'watcher installed: %s\n' "$PLIST"
  printf 'Accounts you sign into from now on get pooled automatically.\n'
  printf 'Log: %s\n' "$STATE/watch.log"
}

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# ------------------------------------------------------------------- main
cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  check)  cmd_check "$@" ;;
  scan)   cmd_scan "$@" ;;
  pool)   cmd_pool "$@" ;;
  status) cmd_status "$@" ;;
  revert) cmd_revert "$@" ;;
  watch)  cmd_watch "$@" ;;
  -h | --help | help | "") usage 0 ;;
  *) printf 'unknown command: %s\n\n' "$cmd" >&2; usage 2 ;;
esac
