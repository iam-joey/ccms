#!/bin/bash
# CCMS - Claude Code Multi-Session
# Share your Claude Code sessions across every Claude account on this Mac.
#
# FOR THE CLAUDE DESKTOP APP ON macOS ONLY. Not the `claude` CLI (its
# transcripts live in ~/.claude/projects and are not account-scoped, so they
# are already shared across accounts) and not the web app.
#
# The desktop app stores each Code session as a small pointer file under
#     <store>/<accountUuid>/<orgUuid>/local_<id>.json
# and builds the sidebar by listing ONLY the folder of the account + workspace
# you are signed into. Switch account - or move a personal plan onto a Team
# plan - and the list looks empty, although every session is still on disk.
#
# ccms moves those pointer files into one shared list and replaces each
# <account>/<workspace> folder with a symlink to it. Every account then reads
# and writes the same list: no copies, no drift, both directions, and new
# sessions show up everywhere at once.
#
# Nothing to install: bash, mv, ln and plutil all ship with macOS.
#
#   ccms check             are the desktop app's files where we expect?
#   ccms scan              accounts, workspaces and session counts
#   ccms share             dry-run: exactly what would change
#   ccms share --apply     do it (writes an undo log)
#   ccms status            are the links still intact?
#   ccms revert --apply    undo, putting every session back where it came from
#   ccms watch --install   share accounts you sign into later, automatically
#
# MIT licence.

set -u

VERSION="1.0"
POOL_DIRNAME="_pool"
POOL_NAME="everything"
# The symlink target, relative to the account folder the link sits in. This
# MUST stay in step with pool_path() below - one absolute spelling, one
# relative, and nothing but this comment keeping them honest.
POOL_REL="../$POOL_DIRNAME/$POOL_NAME"
AGENT_LABEL="com.ccms.watch"

# The two per-account+workspace session stores the desktop app keeps.
STORES="claude-code-sessions local-agent-mode-sessions"

# A session is local_<id>.json. EVERYTHING ELSE in an account folder is
# per-account state (scheduled-tasks.json today, an rpm/ directory and whatever
# the app adds next), and a folder symlink cannot keep it separate. Deriving
# the set from the session pattern means a new file the app invents is handled
# the day it appears, instead of the day someone updates a hardcoded list.
is_session() { case "${1##*/}" in local_*.json) return 0 ;; esac; return 1; }

SUPPORT="${CCMS_SUPPORT:-$HOME/Library/Application Support/Claude}"
STATE="${CCMS_HOME:-$HOME/.ccms}"
MANIFEST="$STATE/manifest.tsv"
BACKUPS="$STATE/backups"
PLIST="${CCMS_PLIST:-$HOME/Library/LaunchAgents/$AGENT_LABEL.plist}"

TAB=$(printf '\t')
NL='
'
PREFLIGHT_OK=1
ROWS=""            # each_folder's output, computed once by preflight
ACCT_DB=""         # accounts.tsv held in memory
CS_CACHE=""        # session counts, keyed by directory
NO_BANNER="${CCMS_NO_BANNER:-0}"

# --------------------------------------------------------------------- look
# Colour only for a real terminal, and never when NO_COLOR is set
# (https://no-color.org). Piped or redirected output stays plain text.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
  E=$(printf '\033')
  C_OFF="$E[0m"; C_B="$E[1m"; C_DIM="$E[2m"
  C_CYAN="$E[36m"; C_GREEN="$E[32m"; C_RED="$E[31m"
  C_YELLOW="$E[33m"; C_BLUE="$E[34m"
else
  C_OFF=; C_B=; C_DIM=; C_CYAN=; C_GREEN=; C_RED=; C_YELLOW=; C_BLUE=
fi

pass() { printf '  %s✓%s  %s\n' "$C_GREEN" "$C_OFF" "$1"; }
fail() { printf '  %s✗%s  %s%s%s\n' "$C_RED" "$C_OFF" "$C_B" "$1" "$C_OFF"; }
warn() { printf '  %s!%s  %s\n' "$C_YELLOW" "$C_OFF" "$1"; }
note() { printf '     %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }
info() { printf '  %s·  %s%s\n' "$C_DIM" "$1" "$C_OFF"; }
rule() { printf '  %s────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_OFF"; }

heading() {
  printf '\n  %s%s%s\n' "$C_B" "$1" "$C_OFF"
  rule
}

dry_run_notice() {
  heading "Dry run"
  printf '  Nothing has changed. Run %sccms %s --apply%s to do it.\n\n' \
    "$C_B" "$1" "$C_OFF"
}

# The name card. Draws once, for about two seconds, then gets out of the way.
# Skipped when piped or under launchd, and by --no-banner / CCMS_NO_BANNER=1,
# so logs and scripts are never slowed down by decoration.
banner() {
  [ "$NO_BANNER" = 1 ] && return 0
  [ -t 1 ] || return 0
  local line
  printf '\n'
  while IFS= read -r line; do
    printf '  %s%s%s%s\n' "$C_B" "$C_CYAN" "$line" "$C_OFF"
    sleep 0.09
  done <<'ART'
 ██████╗ ██████╗███╗   ███╗███████╗
██╔════╝██╔════╝████╗ ████║██╔════╝
██║     ██║     ██╔████╔██║███████╗
██║     ██║     ██║╚██╔╝██║╚════██║
╚██████╗╚██████╗██║ ╚═╝ ██║███████║
 ╚═════╝ ╚═════╝╚═╝     ╚═╝╚══════╝
ART
  sleep 0.2
  printf '\n  %sClaude Code Multi-Session%s %sv%s%s\n' \
    "$C_B" "$C_OFF" "$C_DIM" "$VERSION" "$C_OFF"
  printf '  %sClaude Code sessions, shared across every account%s\n' "$C_DIM" "$C_OFF"
  sleep 1.3
  printf '\n'
}

die() { printf '%s\n' "$*" >&2; exit 2; }

# ---------------------------------------------------------------- helpers

is_uuid() {
  # The glob below matches whole-word with one ? per character, so a match
  # already implies 36 characters - no separate length test needed.
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

# The one shared list for a store, and where a replaced folder is kept.
pool_path() { printf '%s/%s/%s/%s' "$SUPPORT" "$1" "$POOL_DIRNAME" "$POOL_NAME"; }
backup_folder() { printf '%s/%s/%s/%s.folder' "$BACKUPS" "$1" "$2" "$3"; }

# The undo log: one row per thing done, same six columns every time.
#   kind <TAB> store <TAB> account <TAB> workspace <TAB> target <TAB> origin
manifest_add() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "${6:-}" >>"$MANIFEST"
}

# This script's own path, resolved once: it goes into the launchd agent and is
# reported to the user, and those two must not be able to disagree.
SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"

# Counts session files in a directory into $CNT. Pooled folders are all
# symlinks to one directory, so the caller passes a key ("pool:<store>") that
# collapses them and the directory is read once instead of once per account.
CNT=0
count_sessions() {
  local key="$1" dir="${2:-$1}" rest n=0 f
  case "$CS_CACHE" in
    *"$NL$key$TAB"*) rest=${CS_CACHE#*"$NL$key$TAB"}; CNT=${rest%%"$NL"*}; return 0 ;;
  esac
  for f in "$dir"/local_*.json; do [ -e "$f" ] && n=$((n + 1)); done
  CNT=$n
  CS_CACHE="$CS_CACHE$NL$key$TAB$n"
}

# The directory whose sessions a folder actually shows, as a cache key. Linked
# folders share one pool per store; anything else is counted on its own.
count_key() {
  case "$2" in
    linked) COUNT_KEY="pool:$1"; COUNT_DIR=$(pool_path "$1") ;;
    folder) COUNT_KEY="$3"; COUNT_DIR="$3" ;;
    *)      COUNT_KEY=$(resolve "$3"); COUNT_DIR="$3"
            [ -n "$COUNT_KEY" ] || COUNT_KEY="$3" ;;
  esac
}

# plutil reads JSON as happily as it reads plists, and ships with macOS - so no
# jq, no python. Missing key or missing file just yields "".
jget() { local v; v=$(plutil -extract "$2" raw -o - "$1" 2>/dev/null); printf '%s' "${v%%"$NL"*}"; }

# Remember uuid -> email for whichever account is signed in right now, so later
# runs can label folders even while signed into a different account.
learn_accounts() {
  local cli="$HOME/.claude.json" uuid email org orgname
  [ -d "$STATE" ] || mkdir -p "$STATE"
  [ -f "$STATE/accounts.tsv" ] || touch "$STATE/accounts.tsv"
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
  [ -n "$ACCT_DB" ] || load_accounts
  case "$ACCT_DB" in *"$NL$id$TAB"*) return 0 ;; esac
  printf '%s\t%s\n' "$id" "$name" >>"$STATE/accounts.tsv"
  ACCT_DB="$ACCT_DB$id$TAB$name$NL"
}

# Read accounts.tsv once per run. Every folder row needs two lookups, so
# grepping the file per lookup was most of the time `scan` spent.
load_accounts() {
  local line
  ACCT_DB="$NL"
  [ -f "$STATE/accounts.tsv" ] || return 0
  while IFS= read -r line; do ACCT_DB="$ACCT_DB$line$NL"; done <"$STATE/accounts.tsv"
}

name_of() {
  local id="$1" rest
  [ -n "$ACCT_DB" ] || load_accounts
  case "$ACCT_DB" in
    *"$NL$id$TAB"*) rest=${ACCT_DB#*"$NL$id$TAB"}; printf '%s' "${rest%%"$NL"*}" ;;
    *) printf '%s' "${id:0:8}" ;;
  esac
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
      # Load-bearing: the store root also holds our own _pool, and the app's
      # own `skills-plugin`, whose children are a UUID/UUID pair shaped exactly
      # like <account>/<workspace>. Matching only UUIDs keeps both out of the
      # share set - failing closed on an unknown layout beats moving files
      # that are not ours.
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

# --------------------------------------------------------------- preflight

# Confirms this really is a Claude desktop install whose layout we understand.
# Prints one line per check, naming the exact path, so a failure says which
# thing was wrong instead of just "unsupported". Sets PREFLIGHT_OK.
preflight() {
  local quiet="${1:-}"
  local app ver store found rows accts total acct org kind path seen
  PREFLIGHT_OK=1

  if [ "$(uname -s)" = Darwin ]; then
    pass "macOS $(sw_vers -productVersion 2>/dev/null)"
  else
    fail "this is $(uname -s), not macOS"
    note "ccms only knows the macOS desktop layout. Point CCMS_SUPPORT at"
    note "your store if you know where it is, at your own risk."
    PREFLIGHT_OK=0
  fi

  if app=$(app_bundle); then
    ver=$(jget "$app/Contents/Info.plist" CFBundleShortVersionString)
    pass "Claude desktop app${ver:+ v$ver}"
    note "$app"
  else
    warn "Claude.app not in /Applications or ~/Applications"
    note "Checking the files anyway - a moved app is fine."
  fi

  if [ -d "$SUPPORT" ]; then
    pass "application support"
    note "$SUPPORT"
  else
    fail "no Claude support directory"
    note "$SUPPORT"
    note "Is this the desktop app (claude.ai/download)? The \`claude\` CLI alone"
    note "never creates it. Sign into the app once, or set CCMS_SUPPORT."
    PREFLIGHT_OK=0
    return 0
  fi

  found=""
  for store in $STORES; do
    [ -d "$SUPPORT/$store" ] && found="$found $store"
  done
  if [ -n "$found" ]; then
    pass "session stores"
    for store in $found; do note "$store"; done
  else
    fail "no session store under the support directory"
    for store in $STORES; do note "expected $store"; done
    note "Open one Claude Code session in the desktop app, quit it, then retry."
    PREFLIGHT_OK=0
    return 0
  fi

  ROWS=$(each_folder); rows=$ROWS
  if [ -n "$rows" ]; then
    # `quiet` skips only this summary line; every failure branch above still
    # reports in full. scan and status print their own numbers, so computing
    # these for them would be work thrown away.
    if [ "$quiet" != quiet ]; then
      accts=$(printf '%s\n' "$rows" | cut -f2 | sort -u | wc -l | tr -d ' ')
      total=0
      seen="$NL"
      while IFS="$TAB" read -r store acct org kind path; do
        [ -n "${store:-}" ] || continue
        count_key "$store" "$kind" "$path"
        case "$seen" in *"$NL$COUNT_KEY$NL"*) continue ;; esac
        seen="$seen$COUNT_KEY$NL"
        count_sessions "$COUNT_KEY" "$COUNT_DIR"
        total=$((total + CNT))
      done <<<"$rows"
      pass "$(printf '%s\n' "$rows" | wc -l | tr -d ' ') folders, $accts accounts, $total sessions on disk"
    fi
  else
    fail "the stores exist but hold no <account>/<workspace> folders"
    note "Nothing to share yet. Open a Code session in the app first."
    PREFLIGHT_OK=0
  fi
  return 0
}

# Quiet unless it fails. Redirect rather than $(...): a subshell would lose
# PREFLIGHT_OK.
require_preflight() {
  local tmp
  tmp="${TMPDIR:-/tmp}/ccms.$$"
  preflight quiet >"$tmp" 2>&1
  if [ "$PREFLIGHT_OK" != 1 ]; then
    printf 'ccms works on the Claude DESKTOP app for macOS. This machine:\n\n' >&2
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
  heading "Checking this Mac"
  preflight
  if [ "$PREFLIGHT_OK" != 1 ]; then
    heading "Not ready"
    printf '  Fix the %s✗%s above and run `ccms check` again.\n\n' "$C_RED" "$C_OFF"
    return 2
  fi
  if [ -f "$PLIST" ]; then pass "watcher installed"; else info "watcher not installed"; fi
  heading "Ready"
  printf '  %sccms scan%s   what is on this machine\n' "$C_B" "$C_OFF"
  printf '  %sccms share%s  dry-run, then --apply to do it\n\n' "$C_B" "$C_OFF"
  return 0
}

cmd_scan() {
  require_preflight
  learn_accounts
  local store last="" n mark lbl
  heading "Accounts and workspaces"
  while IFS="$TAB" read -r store acct org kind path; do
    [ -n "${store:-}" ] || continue
    if [ "$store" != "$last" ]; then
      printf '\n  %s%s%s\n' "$C_BLUE" "$store" "$C_OFF"
      last=$store
    fi
    count_key "$store" "$kind" "$path"
    count_sessions "$COUNT_KEY" "$COUNT_DIR"; n=$CNT
    case "$kind" in
      linked)  mark="${C_GREEN}shared${C_OFF}" ;;
      folder)  mark="${C_YELLOW}on its own${C_OFF}" ;;
      relink)  mark="${C_YELLOW}odd link${C_OFF}" ;;
      *)       mark="${C_DIM}left alone${C_OFF}" ;;
    esac
    lbl=$(label_for "$acct" "$org")
    [ ${#lbl} -gt 46 ] && lbl="${lbl:0:45}…"      # keep the columns straight
    printf '    %-46s %s%4s%s  %s\n' "$lbl" "$C_B" "$n" "$C_OFF" "$mark"
  done <<<"$ROWS"
  printf '\n  %sshared%s = reads the common list   '    "$C_GREEN" "$C_OFF"
  printf '%son its own%s = still isolated\n\n' "$C_YELLOW" "$C_OFF"
}

cmd_share() {
  local apply=0 force=0 nowatch=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1 ;;
      --force) force=1 ;;
      --no-watch) nowatch=1 ;;
      *) die "share: unknown option $1" ;;
    esac
    shift
  done

  heading "Checking this Mac"
  preflight
  [ "$PREFLIGHT_OK" = 1 ] || {
    heading "Stopped"
    printf '  Nothing was changed.\n\n' >&2
    exit 2
  }
  learn_accounts

  local rows todo=0 store acct org kind path pool_dir f extras base dest
  rows=$ROWS

  # Report first, so a dry-run and an --apply show the same thing.
  while IFS="$TAB" read -r store acct org kind path; do
    [ -n "${store:-}" ] || continue
    case "$kind" in
      linked) continue ;;
      foreign)
        warn "$(label_for "$acct" "$org") is a symlink outside the store; left alone"
        continue ;;
    esac
    todo=$((todo + 1))
  done <<<"$rows"

  # Assert the watcher's coverage on every apply, not only when something
  # needed sharing: a new account can appear whose workspace an earlier wake
  # already shared, and that run would otherwise leave the watch list stale.
  # Dry runs change nothing, including this.
  [ "$apply" = 1 ] && refresh_watch

  if [ "$todo" -eq 0 ]; then
    heading "Nothing to do"
    printf '  Every folder already reads the shared list.\n\n'
    return 0
  fi

  heading "$([ "$apply" = 1 ] && echo "Sharing $todo folder(s)" || echo "Would share $todo folder(s)")"
  while IFS="$TAB" read -r store acct org kind path; do
    [ -n "${store:-}" ] || continue
    case "$kind" in linked | foreign) continue ;; esac
    printf '\n  %s%s%s  %s%s%s\n' "$C_B" "$(label_for "$acct" "$org")" "$C_OFF" \
      "$C_DIM" "$store" "$C_OFF"
    if [ "$kind" = relink ]; then
      printf '    %s→%s  repoint existing link to the shared list\n' "$C_CYAN" "$C_OFF"
    else
      count_key "$store" "$kind" "$path"
      count_sessions "$COUNT_KEY" "$COUNT_DIR"
      printf '    %s→%s  %s%s%s sessions join the shared list\n' \
        "$C_CYAN" "$C_OFF" "$C_B" "$CNT" "$C_OFF"
      extras=""
      for f in "$path"/*; do
        [ -e "$f" ] && ! is_session "$f" && extras="$extras ${f##*/}"
      done
      [ -n "$extras" ] && note "also shared (backed up first):$extras"
    fi
  done <<<"$rows"

  if [ "$apply" != 1 ]; then
    dry_run_notice share
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

    pool_dir=$(pool_path "$store")
    [ -d "$pool_dir" ] || mkdir -p "$pool_dir"

    if [ "$kind" = relink ]; then
      rm -f "$path"
      ln -s "$POOL_REL" "$path"
      manifest_add link "$store" "$acct" "$org" "$path"
      pass "repointed  $(label_for "$acct" "$org")"
      continue
    fi

    for f in "$path"/local_*.json; do
      [ -e "$f" ] || continue
      if [ -e "$pool_dir/${f##*/}" ]; then continue; fi   # same uuid, same session
      mv "$f" "$pool_dir/${f##*/}"
      manifest_add move "$store" "$acct" "$org" "${f##*/}" "$pool_dir"
    done

    # Per-account state cannot survive a folder symlink. Back all of it up,
    # and put one copy in the shared folder so it is not simply lost. Each
    # copy gets a row, so revert removes exactly what we added.
    for f in "$path"/*; do
      [ -e "$f" ] || continue
      is_session "$f" && continue
      base=${f##*/}
      mkdir -p "$BACKUPS/$store/$acct/$org"
      cp -R -p "$f" "$BACKUPS/$store/$acct/$org/$base"
      [ -e "$pool_dir/$base" ] && continue
      cp -R -p "$f" "$pool_dir/$base"
      manifest_add copy "$store" "$acct" "$org" "$base" "$pool_dir"
    done

    dest=$(backup_folder "$store" "$acct" "$org")
    mkdir -p "$(dirname "$dest")"
    mv "$path" "$dest"
    ln -s "$POOL_REL" "$path"
    manifest_add link "$store" "$acct" "$org" "$path" "$dest"
    pass "shared     $(label_for "$acct" "$org")"
  done <<<"$rows"

  heading "Done"
  printf '  Reopen the Claude desktop app. Every account now shows the same list.\n'
  note "undo log: $MANIFEST"
  [ "$nowatch" = 1 ] || offer_watcher
  printf '\n'
  return 0
}

offer_watcher() {
  [ -f "$PLIST" ] && return 0
  heading "One thing this does not cover"
  printf '  An account you sign into %sLATER%s gets a brand-new empty folder, so it\n' \
    "$C_B" "$C_OFF"
  printf '  has to be shared once more. Two ways to handle that:\n\n'
  printf '    %sno%s   run %sccms share --apply%s yourself after each new sign-in\n' \
    "$C_B" "$C_OFF" "$C_B" "$C_OFF"
  printf '    %syes%s  a macOS LaunchAgent does it for you. It wakes only when one\n' \
    "$C_B" "$C_OFF"
  printf '         of the two store folders changes - no cron, no polling, no\n'
  printf '         process in memory. Undo with %sccms watch --uninstall%s\n\n' \
    "$C_B" "$C_OFF"
  if ask "Install the watcher?"; then
    cmd_watch --install
  else
    note "Skipped. \`ccms watch --install\` sets it up later."
  fi
}

cmd_status() {
  require_preflight
  learn_accounts
  local store acct org kind path bad=0 pooled=0 n msg
  heading "Shared lists"
  for store in $STORES; do
    [ -d "$(pool_path "$store")" ] || continue
    count_sessions "pool:$store" "$(pool_path "$store")"; n=$CNT
    printf '  %-30s %s%s%s sessions\n' "$store" "$C_B" "$n" "$C_OFF"
  done

  while IFS="$TAB" read -r store acct org kind path; do
    [ -n "${store:-}" ] || continue
    case "$kind" in
      linked) pooled=$((pooled + 1)); continue ;;
      folder) msg="not shared  $(label_for "$acct" "$org")" ;;
      *)      msg="odd link    $(label_for "$acct" "$org") ($kind)" ;;
    esac
    [ "$bad" -eq 0 ] && heading "Needs attention"
    warn "$msg"
    note "$store"
    bad=$((bad + 1))
  done <<<"$ROWS"

  if [ "$bad" -eq 0 ]; then
    heading "All good"
    printf '  %s folders, all reading the shared list.\n\n' "$pooled"
    return 0
  fi
  printf '\n  %s folder(s) to fix - run %sccms share --apply%s\n\n' "$bad" "$C_B" "$C_OFF"
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
  moves=$(grep -c "^move$TAB" "$MANIFEST")
  links=$(grep -c "^link$TAB" "$MANIFEST")
  heading "$([ "$apply" = 1 ] && echo Undoing || echo "Would undo")"
  printf '  %s%s%s session files back to their own folders\n' "$C_B" "$moves" "$C_OFF"
  printf '  %s%s%s folders restored\n' "$C_B" "$links" "$C_OFF"
  note "from $MANIFEST"

  if [ "$apply" != 1 ]; then
    dry_run_notice revert
    return 0
  fi
  if app_running && [ "$force" != 1 ]; then
    heading "Quit Claude first"
    printf '  The desktop app is running. Quit it (%sCmd+Q%s), or pass --force.\n\n' \
      "$C_B" "$C_OFF" >&2
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

  # Remove the per-account state we copied into the shared folder. The
  # originals went back with their folders, and the rows say exactly what we
  # put there, so nothing is guessed at.
  while IFS="$TAB" read -r w s acct org p b; do
    [ "$w" = copy ] || continue
    [ -n "${b:-}" ] && [ -n "${p:-}" ] && rm -rf "${b:?}/${p:?}"
  done <"$MANIFEST"

  for store in $STORES; do
    pool=$(pool_path "$store")
    [ -d "$pool" ] || continue

    count_sessions "revert:$store" "$pool"; left=$CNT
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
        warn "$left session(s) started while shared had no folder to return to"
        note "moved them to $dest"
      else
        warn "$left session(s) left in $pool - no folder to return them to" >&2
      fi
    fi

    rmdir "$pool" 2>/dev/null
    rmdir "$SUPPORT/$store/$POOL_DIRNAME" 2>/dev/null
  done

  mv "$MANIFEST" "$MANIFEST.reverted"
  heading "Reverted"
  printf '  Every account is back to its own separate list.\n'
  note "backups kept in $BACKUPS"
  printf '\n' 
}

# Minimal XML escaping for paths that go into the plist.
xml_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Everything launchd has to watch.
#
# A new ACCOUNT appears as a new folder inside a store root, so watching the
# store root catches it. A new WORKSPACE appears inside an existing account
# folder - joining a Team, for instance - and that does NOT change the store
# root's mtime at all. Watch only the store roots and a new workspace is
# invisible, which is exactly the case that catches people out. So both levels
# are watched.
watch_paths() {
  local store acct
  for store in $STORES; do
    [ -d "$SUPPORT/$store" ] || continue
    printf '%s\n' "$SUPPORT/$store"
    for acct in "$SUPPORT/$store"/*; do
      [ -d "$acct" ] || continue
      is_uuid "${acct##*/}" && printf '%s\n' "$acct"
    done
  done
}

write_plist() {
  local watched path
  watched=""
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    watched="$watched$(printf '\n    <string>%s</string>' "$(xml_esc "$path")")"
  done <<<"$(watch_paths)"
  [ -n "$watched" ] || return 1

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
    <string>$(xml_esc "$SELF")</string>
    <string>share</string>
    <string>--apply</string>
    <string>--force</string>
    <string>--no-watch</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CCMS_SUPPORT</key><string>$(xml_esc "$SUPPORT")</string>
    <key>CCMS_HOME</key><string>$(xml_esc "$STATE")</string>
  </dict>
  <key>WatchPaths</key>
  <array>$watched
  </array>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$(xml_esc "$STATE/watch.log")</string>
  <key>StandardErrorPath</key><string>$(xml_esc "$STATE/watch.log")</string>
</dict>
</plist>
EOT
  watch_paths >"$STATE/watch-paths.txt"
  return 0
}

# Accounts that appear AFTER the watcher was installed need watching too, or
# the first new workspace under one of them is missed. Cheap to re-check, and
# it only rewrites the agent when the set of paths actually changed.
refresh_watch() {
  [ -f "$PLIST" ] || return 0
  local now
  now=$(watch_paths)
  [ "$now" = "$(cat "$STATE/watch-paths.txt" 2>/dev/null)" ] && return 0
  write_plist || return 0
  launchctl unload "$PLIST" 2>/dev/null
  launchctl load "$PLIST" 2>/dev/null
  info "watcher now covers $(printf '%s\n' "$now" | wc -l | tr -d ' ') paths"
  return 0
}

cmd_watch() {
  local mode="${1:-}"
  case "$mode" in
    --uninstall)
      launchctl unload "$PLIST" 2>/dev/null
      rm -f "$PLIST" "$STATE/watch-paths.txt"
      pass "watcher removed"
      return 0 ;;
    --install) ;;
    "") if [ -f "$PLIST" ]; then
          pass "watcher installed"
          note "covers $(wc -l <"$STATE/watch-paths.txt" 2>/dev/null | tr -d ' ') paths"
        else
          info "watcher not installed"
        fi
        return 0 ;;
    *) die "watch: unknown option $mode" ;;
  esac

  write_plist || die "no store to watch."
  launchctl unload "$PLIST" 2>/dev/null
  launchctl load "$PLIST" || die "launchctl could not load $PLIST"
  heading "Watcher installed"
  pass "new accounts AND new workspaces are shared automatically"
  note "watching $(wc -l <"$STATE/watch-paths.txt" | tr -d ' ') paths"
  note "runs: $SELF"
  note "$PLIST"
  note "log: $STATE/watch.log"
  printf '\n'
}

usage() {
  heading "Commands"
  printf '  %-22s %s\n' "ccms check"          "are the desktop app's files where we expect?"
  printf '  %-22s %s\n' "ccms scan"           "accounts, workspaces and session counts"
  printf '  %-22s %s\n' "ccms share"          "dry-run: exactly what would change"
  printf '  %-22s %s\n' "ccms share --apply"  "do it"
  printf '  %-22s %s\n' "ccms status"         "are the links still intact?"
  printf '  %-22s %s\n' "ccms revert --apply" "undo: every session back where it was"
  printf '  %-22s %s\n' "ccms watch --install" "share accounts you sign into later"
  heading "Options"
  printf '  %-22s %s\n' "--force"      "proceed even if the Claude app is running"
  printf '  %-22s %s\n' "--no-banner"  "skip the name card (also CCMS_NO_BANNER=1)"
  printf '  %-22s %s\n' "--no-watch"   "do not ask about the watcher after sharing"
  heading "Where things live"
  printf '  %-22s %s\n' "CCMS_SUPPORT" "$SUPPORT"
  printf '  %-22s %s\n' "CCMS_HOME"    "$STATE"
  printf '\n  Claude desktop app on macOS only - not the `claude` CLI, whose\n'
  printf '  transcripts are already shared across accounts.\n\n'
  exit "${1:-0}"
}

# ------------------------------------------------------------------- main
# A global --no-banner may appear anywhere; strip it before dispatch.
ARGS=()
for a in ${1+"$@"}; do
  case "$a" in
    --no-banner) NO_BANNER=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- ${ARGS+"${ARGS[@]}"}

cmd="${1:-}"
[ $# -gt 0 ] && shift

banner

case "$cmd" in
  check)        cmd_check ;;
  scan)         cmd_scan ;;
  share)        cmd_share "$@" ;;
  status)       cmd_status ;;
  revert)       cmd_revert "$@" ;;
  watch)        cmd_watch "$@" ;;
  -h | --help | help | "") usage 0 ;;
  *) printf '  %sunknown command: %s%s\n' "$C_RED" "$cmd" "$C_OFF" >&2; usage 2 ;;
esac
