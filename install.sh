#!/bin/bash

# Installs omavikunja into Omarchy. Safe to re-run.
#
# One rule governs this script: it writes nothing outside omavikunja's own
# directories. The symlink into ~/.config/omarchy/plugins is ours to make, and
# registration goes through omarchy's own commands because they own
# ~/.config/omarchy/shell.json. Anything that would change a file you own — the
# keybinding in ~/.config/hypr/bindings.lua — is printed for you to paste. A
# plugin that rewrites your compositor config is one you have to trust twice.

set -euo pipefail

# Resolved rather than assumed, so the script works from any working directory
# and the link points at this checkout rather than at $PWD. -P because the
# comparison below is against readlink -f, which resolves all the way down.
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ID="cschaba.omavikunja"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
BINDINGS="$HOME/.config/hypr/bindings.lua"

# The widget publishes its own IpcHandler under this target (BarWidget.qml,
# `ipcTarget`), and Ui/Panel.qml gives that handler open/close/toggle. So the
# pulldown is addressed by name, not through the shell's generic surface toggle.
TOGGLE_CMD="omarchy-shell cschaba.omavikunja.widget toggle"
# V for Vikunja, and free in Omarchy's own defaults at the time of writing.
CHORD="SUPER + ALT + V"

say() { echo "  $*"; }

# --- 0. is this even an Omarchy machine? ------------------------------------
#
# Asked before anything is written, not after. This check used to live with the
# registration below, which meant a run on a machine without Omarchy created
# ~/.config/omarchy/plugins and a symlink into it *first* and only then stopped
# — leaving two things behind on the one path where the script does nothing
# useful. The rule at the top of this file is that it writes nothing outside
# omavikunja's own directories, and a failure path is exactly where a rule like
# that earns its keep.

if ! command -v omarchy >/dev/null 2>&1; then
  echo
  say "! omarchy was not found on PATH."
  say "  omavikunja is an Omarchy plugin, and registering it means writing"
  say "  ~/.config/omarchy/shell.json — a file omarchy owns and this script"
  say "  will not touch itself. Install Omarchy, then re-run:"
  say "      $SOURCE_DIR/install.sh"
  exit 1
fi

# --- 1. the plugin directory ------------------------------------------------
#
# A symlink and not a copy: the checkout stays the only copy of the code, so an
# edit is live after a shell restart, with nothing to reinstall in between.

if [[ -L $PLUGIN_DIR ]]; then
  # readlink -f on a link into thin air still prints a path and can fail, and
  # neither is worth stopping for — it gets replaced either way.
  current="$(readlink -f "$PLUGIN_DIR" 2>/dev/null || true)"
  if [[ $current == "$SOURCE_DIR" ]]; then
    say "✓ already linked from $SOURCE_DIR"
  else
    # Replacing a symlink destroys nothing — whatever it pointed at is still
    # there. Name it anyway, in case it was another checkout being tested.
    ln -sfn "$SOURCE_DIR" "$PLUGIN_DIR"
    say "✓ relinked $PLUGIN_DIR → $SOURCE_DIR (was ${current:-a broken link})"
  fi
elif [[ -e $PLUGIN_DIR ]]; then
  # A real directory means somebody's files: an `omarchy plugin add` clone, or
  # an older copy-install. Deleting it is not this script's call to make.
  say "! $PLUGIN_DIR exists and is not a link to this checkout."
  say "  omavikunja is installed there some other way, and its files are not"
  say "  mine to delete. Remove that copy with"
  say "      omarchy plugin remove $PLUGIN_ID"
  say "  or move it aside, then re-run this script."
  exit 1
else
  mkdir -p "$(dirname "$PLUGIN_DIR")"
  ln -sfn "$SOURCE_DIR" "$PLUGIN_DIR"
  say "✓ linked $SOURCE_DIR → $PLUGIN_DIR"
fi

# --- 2. the connection: server URL and API token ----------------------------
#
# docs/ARCHITECTURE.md, decision 1: one file, ours, holding the token. Asked for
# once, written once, never overwritten — an existing config is the user's,
# and a re-run is how they check it, not how they lose it.
#
# The token is a secret that can change every task its owner can see, so it is
# read without echo, never printed, and never put on a command line: argv is
# readable by every process on the machine. The connection check hands it to
# curl on stdin.

# Validation is what keeps the JSON below well-formed: neither value can hold
# a quote, a backslash or a control character once it has passed, so printf
# can write them between quotes with nothing to escape. LC_ALL=C pins the
# ranges to ASCII — in some locales [A-Za-z] matches letters well outside it.
valid_url() {
  local LC_ALL=C
  [[ $1 =~ ^https?://[^/?#]+ ]] || return 1
  [[ $1 != *[\"\\[:space:][:cntrl:]]* ]]
}

valid_token() {
  local LC_ALL=C
  [[ $1 =~ ^tk_[A-Za-z0-9]+$ ]]
}

# The host part of a URL, lowercased, without userinfo or port. An IPv6
# literal keeps its brackets, which is how it is compared below.
url_host() {
  local host="${1#*://}"
  host="${host%%[/?#]*}"
  host="${host##*@}"
  if [[ $host == \[* ]]; then
    host="${host%%]*}]"
  else
    host="${host%%:*}"
  fi
  printf '%s' "${host,,}"
}

# A warning, not a refusal: plain HTTP to the machine itself is a reasonable
# setup, and to anywhere else it may be a LAN the user trusts. But they should
# hear it before the token goes out, not after.
warn_cleartext() {
  local url=$1 host
  [[ $url == http://* ]] || return 0
  host="$(url_host "$url")"
  case "$host" in
    localhost | 127.0.0.1 | "[::1]") return 0 ;;
  esac
  echo
  say "! $url is plain http:// to $host, which is not this machine."
  say "  Every request carries your API token, and over http:// it crosses the"
  say "  network in clear text. Use https:// if the server offers it."
}

# GET /api/v2/user is the cheapest request that proves both halves: the URL
# reaches a Vikunja with API v2, and the token is accepted with the `other:
# user` scope the plugin needs. Advisory only — a server that is down today is
# not a reason to fail an install.
#
# The header goes in on stdin (`-H @-`): printf is a builtin, so the token is
# in no process's argv. No -L: a redirect would carry our header to wherever
# it points, so a 3xx is reported instead of followed.
check_connection() {
  local url=$1 token=$2 result code location
  [[ -n $url && -n $token ]] || return 0
  if ! command -v curl >/dev/null 2>&1; then
    say "· curl not found — skipped the connection check"
    return 0
  fi
  echo
  say "Checking the connection to $url ..."
  if ! result="$(printf 'Authorization: Bearer %s\n' "$token" |
    curl -sS --proto '=http,https' --connect-timeout 5 --max-time 15 \
      -o /dev/null -w '%{http_code} %{redirect_url}' -H @- \
      "$url/api/v2/user" 2>&1)"; then
    # curl's own message names the host and what went wrong, never a header.
    # Its -w output can trail it ("000 "); only the message is worth showing.
    say "! could not reach the server:"
    printf '%s\n' "$result" | sed -e '/^000 *$/d' -e 's/000 *$//' -e 's/^/      /'
    say "  Check the URL in $CONFIG_FILE, then re-run this script to try again."
    return 0
  fi
  code="${result%% *}"
  location="${result#* }"
  case "$code" in
    200)
      say "✓ the server accepted the token"
      ;;
    401 | 403)
      say "! the server answered $code: the token was refused. Check that it is"
      say "  current and has the scopes listed in the README (other: user among"
      say "  them), then correct it in $CONFIG_FILE."
      ;;
    404)
      say "! the server answered 404 for /api/v2/user. Either the URL does not"
      say "  point at Vikunja's root, or the server is older than 2.4.0 and has"
      say "  no API v2. OmaVikunja needs 2.4.0 or newer."
      ;;
    3??)
      say "! the server answered $code, a redirect${location:+ to $location}."
      say "  Put the URL it redirects to in $CONFIG_FILE — the token is not sent"
      say "  on to a redirect."
      ;;
    *)
      say "! the server answered HTTP $code — not what a Vikunja API v2 sends."
      ;;
  esac
}

# Asked until the answer is valid or blank; blank (or end of input) leaves the
# field empty, for the user to fill in later.
ask_url() {
  local answer
  while :; do
    read -r -p "  Vikunja server URL (e.g. https://vikunja.example.com, blank to skip): " answer || answer=""
    # Trailing slashes off, so "$url/api/v2" never becomes "//api/v2".
    while [[ $answer == */ ]]; do answer="${answer%/}"; done
    if [[ -z $answer ]] || valid_url "$answer"; then
      REPLY_URL=$answer
      return 0
    fi
    say "! that is not an http:// or https:// URL without quotes, backslashes or spaces"
  done
}

ask_token() {
  local answer
  while :; do
    # -s: no echo. The newline the user typed is not echoed either, so add one.
    read -r -s -p "  API token (tk_…, input hidden, blank to skip): " answer || answer=""
    echo >&2
    if [[ -z $answer ]] || valid_token "$answer"; then
      REPLY_TOKEN=$answer
      return 0
    fi
    # The rejected value is not repeated: it may be a real token mistyped.
    say "! that is not a Vikunja API token — they look like tk_ followed by letters and digits"
  done
}

# Written whole or not at all, and never over an existing file. mktemp creates
# the temporary file 0600 before a byte is in it, so there is no moment when the
# token is readable by anyone else; `ln` then gives it its real name and, unlike
# mv, fails rather than replace a config.json that appeared in the meantime.
write_config() {
  local url=$1 token=$2 tmp
  valid_url "$url" || [[ -z $url ]] || return 1
  valid_token "$token" || [[ -z $token ]] || return 1
  # Every step checked by hand: this runs as an `if` condition, and bash
  # switches set -e off inside one, subshell included.
  (
    umask 077
    mkdir -p "$CONFIG_DIR" && chmod 0700 "$CONFIG_DIR" || exit 1
    tmp="$(mktemp "$CONFIG_DIR/.config.json.XXXXXX")" || exit 1
    trap 'rm -f "$tmp"' EXIT
    printf '{\n  "schemaVersion": 1,\n  "serverUrl": "%s",\n  "apiToken": "%s",\n  "refreshIntervalSec": 300\n}\n' \
      "$url" "$token" >"$tmp" || exit 1
    ln "$tmp" "$CONFIG_FILE"
  )
}

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omavikunja"
CONFIG_FILE="$CONFIG_DIR/config.json"

echo
if [[ -e $CONFIG_FILE || -L $CONFIG_FILE ]]; then
  say "✓ kept the existing $CONFIG_FILE"
  # Only reported, not changed: the file is the user's now, and a mode they set
  # on purpose is theirs to keep.
  mode="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo "")"
  if [[ -n $mode && $mode != 600 && $mode != 400 ]]; then
    say "! it is mode $mode, and it holds your API token. Make it yours only:"
    say "      chmod 600 $CONFIG_FILE"
  fi
  # A re-run is how a user who filled the file in by hand checks it. Without
  # jq there is no safe way to read JSON from bash, so the check is skipped.
  if command -v jq >/dev/null 2>&1; then
    url="$(jq -r '.serverUrl // "" | strings' "$CONFIG_FILE" 2>/dev/null || true)"
    token="$(jq -r '.apiToken // "" | strings' "$CONFIG_FILE" 2>/dev/null || true)"
    url="${url%/}"
    if [[ -n $url ]] && valid_url "$url"; then
      warn_cleartext "$url"
      valid_token "$token" && check_connection "$url" "$token"
    fi
    unset token
  fi
else
  REPLY_URL=""
  REPLY_TOKEN=""
  if [[ -t 0 ]]; then
    say "OmaVikunja needs your Vikunja server and an API token. Create the token"
    say "in Vikunja under Settings → API Tokens; the README lists its scopes."
    echo
    ask_url
    ask_token
  fi
  if ! write_config "$REPLY_URL" "$REPLY_TOKEN"; then
    say "! could not write $CONFIG_FILE"
    exit 1
  fi
  say "✓ wrote $CONFIG_FILE (readable by you only)"
  if [[ -z $REPLY_URL || -z $REPLY_TOKEN ]]; then
    say "  Fill in what is still empty — serverUrl and apiToken — in that file,"
    say "  then re-run this script to check the connection:"
    say "      \${EDITOR:-nano} $CONFIG_FILE"
  fi
  [[ -n $REPLY_URL ]] && warn_cleartext "$REPLY_URL"
  check_connection "$REPLY_URL" "$REPLY_TOKEN"
  unset REPLY_TOKEN
fi

# --- 3. registration, through omarchy's own commands ------------------------

# The shell keeps its own list of what is installed, and a directory that
# appeared after it started is not on it. Quiet and best-effort: with no shell
# running there is nobody to tell, and that is not a failure.
omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true

# ...and then wait for it to land. rescanPlugins is fire-and-forget: the IPC
# call returns when the shell accepts it, not when the scan has finished, so
# enabling on the next line asks about a plugin the shell has not read yet and
# is told it does not exist. It takes about 50ms here. omarchy-plugin-add has
# the same problem and solves it the same way, polling the plugin list rather
# than sleeping a guessed amount.
#
# This is what made a fresh install fail while reporting nothing: `-q` returns
# success even when the call does nothing, so a rescan that never happened and
# one that worked look identical from here.
plugin_known() {
  omarchy plugin list 2>/dev/null | grep -qF "$PLUGIN_ID"
}

wait_for_discovery() {
  local attempt
  for (( attempt = 0; attempt < 40; attempt++ )); do
    plugin_known && return 0
    sleep 0.05
  done
  return 1
}

# Where the widget goes, asked once rather than assumed. This mirrors
# select_bar_widget_placement() in omarchy-plugin-add: the manifest's own
# defaultSection is the pre-selection, and a non-interactive run or a missing
# gum takes that default silently — install.sh has to stay scriptable.
PLACEMENT=()
choose_placement() {
  local default_section chosen
  [[ -t 0 && -t 1 ]] || return 0
  command -v gum >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  default_section=$(jq -r '.barWidget.defaultSection // "center"' "$SOURCE_DIR/manifest.json" 2>/dev/null) || return 0
  chosen=$(printf '%s\n' left center right |
    gum choose --header="Place omavikunja in which bar section?" --selected "$default_section") || return 0
  [[ -n $chosen ]] || return 0
  PLACEMENT=(--section "$chosen")
}

register() {
  # `plugin enable` places a bar widget as well as enabling it, and leaves an
  # entry that is already in the layout where it is.
  omarchy plugin enable "$PLUGIN_ID" "${PLACEMENT[@]}" || return 1
  # `bar put` is the unattended verb: it leaves a widget that is already on the
  # bar exactly where its owner put it, and waits out a shell that is still
  # starting up. After a successful enable it changes nothing — which is what
  # makes a second run of this script produce one widget rather than two.
  omarchy bar put "$PLUGIN_ID" || return 1
}

if ! wait_for_discovery; then
  say "! the shell has not picked omavikunja up."
  say "  That is what happens when omarchy-shell is not running — start it, or"
  say "  restart it, and this script will work on the next run:"
  say "      omarchy restart shell"
  say "      $SOURCE_DIR/install.sh"
  exit 1
fi

choose_placement

if register_output="$(register 2>&1)"; then
  say "✓ enabled, and the widget is on the bar"
else
  say "! omarchy could not register omavikunja. It said:"
  printf '%s\n' "$register_output" | sed 's/^/      /'
  say "  Run these once the shell is up:"
  say "      omarchy plugin enable $PLUGIN_ID"
  say "      omarchy bar put $PLUGIN_ID"
fi

# --- 4. the keybinding, which is yours to add -------------------------------

echo
if [[ -f $BINDINGS ]] && grep -qF "$TOGGLE_CMD" "$BINDINGS"; then
  say "✓ a keybinding for the pulldown is already in $BINDINGS"
else
  say "The pulldown opens from its bar icon. If you want a key for it too —"
  say "one step, in a file that belongs to you — add this to $BINDINGS:"
  echo
  echo "    -- omavikunja"
  echo "    o.bind(\"$CHORD\", \"Vikunja tasks\", \"$TOGGLE_CMD\")"
  echo
  say "then reload with:  hyprctl reload"

  # Only your own overrides are checked, not Hyprland's whole binding list.
  # The binding is optional and there is no omavikunja config to move the chord
  # to, so a conflict here is worth a sentence, not an interrogation — and the
  # file you are about to paste into is the one place a surprise would live.
  if [[ -f $BINDINGS ]] && grep -qF "\"$CHORD\"" "$BINDINGS"; then
    echo
    say "! $CHORD already appears in that file. Pick a free chord in the line"
    say "  above; Omarchy's own bindings are listed by:"
    say "      omarchy menu keybindings --print"
  fi
fi

# --- 5. what happens next ---------------------------------------------------

echo
say "omavikunja installed. Restart the shell to load it:"
say "    omarchy restart shell"
say "omarchy-shell reads a plugin's QML once at startup and keeps it for the"
say "life of the process, so a restart is also how you see any later edit."
