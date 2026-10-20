#!/bin/bash

# install.sh and uninstall.sh against a throwaway HOME: the config file they
# write or leave alone, its permissions, the connection check, the clear-text
# warning, --purge, and that nothing is written anywhere else.
#
# omarchy, omarchy-shell and gum are stubbed on PATH, so this runs on a machine
# without Omarchy (CI) and cannot touch a real one's shell or bar. curl is real
# but wrapped, to record its argv: the token must never be in it. The Vikunja
# it talks to is a few lines of python on 127.0.0.1 — no network, no real
# server, no real token. The interactive cases run under a pty, because that is
# the only way to see what a user would see, and to see what they would not:
# the token, which is read without echo.

# Each check is a string that `yes` evals, so it reads as one line per claim.
# The linter cannot see inside those strings: single quotes are the point
# (SC2016), and variables used only there look unused (SC2034).
# shellcheck disable=SC2016,SC2034

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [[ -n $SERVER_PID ]] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33m—\033[0m %s\n' "$1"; }
yes()  { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "omavikunja installer test"

if ! command -v python3 >/dev/null 2>&1; then
  skip "python3 unavailable — skipped the installer tests"
  exit 0
fi

# A placeholder, as everywhere in this repository. Never a real one.
TOKEN="tk_example0123456789"
REAL_CURL="$(command -v curl || true)"

# --- stubs --------------------------------------------------------------------

STUBS="$TMP/bin"
mkdir -p "$STUBS"

cat >"$STUBS/omarchy" <<'EOF'
#!/bin/bash
echo "omarchy $*" >>"$STUB_LOG"
[[ "$1 $2" == "plugin list" ]] && echo "cschaba.omavikunja"
exit 0
EOF

cat >"$STUBS/omarchy-shell" <<'EOF'
#!/bin/bash
echo "omarchy-shell $*" >>"$STUB_LOG"
exit 0
EOF

# Omarchy machines have gum, and under a pty install.sh would open its section
# picker. Answer it the way a user taking the default would.
cat >"$STUBS/gum" <<'EOF'
#!/bin/bash
echo center
EOF

if [[ -n $REAL_CURL ]]; then
  cat >"$STUBS/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"\$CURL_ARGV_LOG"
exec "$REAL_CURL" "\$@"
EOF
fi
chmod +x "$STUBS"/*

# --- a stand-in Vikunja ------------------------------------------------------
#
# /api/v2/user answers 200 for the one placeholder token, 401 for anything else
# and 404 for every other path. It also records the Authorization header it
# got, which is how the test knows curl sent it at all.

cat >"$TMP/fake_vikunja.py" <<'EOF'
import http.server, sys

token, portfile, seen = sys.argv[1], sys.argv[2], sys.argv[3]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        with open(seen, "a") as f:
            f.write(self.path + " " + auth + "\n")
        if self.path != "/api/v2/user":
            self.send_response(404)
        elif auth == "Bearer " + token:
            self.send_response(200)
        else:
            self.send_response(401)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(portfile, "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
EOF

python3 -I "$TMP/fake_vikunja.py" "$TOKEN" "$TMP/port" "$TMP/seen" &
SERVER_PID=$!
for _ in $(seq 50); do [[ -s $TMP/port ]] && break; sleep 0.1; done
PORT="$(cat "$TMP/port" 2>/dev/null || echo "")"
LOCAL_URL="http://127.0.0.1:$PORT"

# --- a pty driver ------------------------------------------------------------
#
# Runs a command on a pty and types the given answers, one per prompt. What the
# terminal showed goes to stdout, so a hidden token can be looked for in it.

cat >"$TMP/tty_driver.py" <<'EOF'
import os, pty, select, subprocess, sys, time

answers = sys.argv[1].split("\x1f") if sys.argv[1] else []
command = sys.argv[2:]
master, slave = pty.openpty()
child = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave, close_fds=True)
os.close(slave)
seen = b""
sent = 0
deadline = time.time() + 60
while time.time() < deadline:
    ready, _, _ = select.select([master], [], [], 0.2)
    if ready:
        try:
            chunk = os.read(master, 4096)
        except OSError:
            chunk = b""
        if not chunk:
            break
        seen += chunk
        if seen.count(b"blank to skip): ") > sent:
            os.write(master, (answers[sent] if sent < len(answers) else "").encode() + b"\n")
            sent += 1
    elif child.poll() is not None:
        break
child.wait()
sys.stdout.write(seen.decode("utf-8", "replace"))
sys.exit(child.returncode)
EOF

# --- running the scripts -----------------------------------------------------

# A fresh HOME per case, with the XDG variables gone so the defaults the
# README documents are what get tested. No proxy: everything here is local.
fresh_home() {
  H="$(mktemp -d "$TMP/home.XXXXXX")"
  CONFIG="$H/.config/omavikunja/config.json"
  : >"$TMP/argv"
  : >"$TMP/stubs.log"
}

run_env() {
  env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u http_proxy -u https_proxy \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
    HOME="$H" PATH="$STUBS:$PATH" STUB_LOG="$TMP/stubs.log" CURL_ARGV_LOG="$TMP/argv" \
    "$@"
}

# Not interactive: stdin is not a terminal.
install_batch() { run_env bash "$ROOT/install.sh" </dev/null >"$TMP/out" 2>&1; }

# Interactive: answers separated by \x1f, one per prompt.
install_tty() {
  local IFS=$'\x1f'
  run_env python3 -I "$TMP/tty_driver.py" "$*" bash "$ROOT/install.sh" >"$TMP/out" 2>&1
}

has() { grep -qF -- "$1" "$TMP/out"; }
mode() { stat -c "%a" "$1" 2>/dev/null; }
json() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$1" 2>/dev/null; }
expect_json() {
  python3 -c 'import json,sys; print(json.dumps({"schemaVersion": 1, "serverUrl": sys.argv[1], "apiToken": sys.argv[2], "refreshIntervalSec": 300}, sort_keys=True))' "$1" "$2"
}
show_output() { sed 's/^/        | /' "$TMP/out"; }

# Everything install.sh may leave in HOME, and nothing else.
EXPECTED_TREE=".config
.config/omarchy
.config/omarchy/plugins
.config/omarchy/plugins/cschaba.omavikunja
.config/omavikunja
.config/omavikunja/config.json"
tree() { (cd "$H" && find . -mindepth 1 | sed 's|^\./||' | sort); }

# --- fresh install, interactive ---------------------------------------------

echo
echo "fresh install, interactive"
if [[ -z $PORT ]]; then
  bad "the stand-in server did not start"
else
  fresh_home
  if install_tty "$LOCAL_URL/" "$TOKEN"; then ok "install.sh succeeds"; else bad "install.sh failed"; show_output; fi
  yes "config.json is written" '[[ -f $CONFIG ]]'
  yes "config.json is valid JSON with the answers (trailing slash dropped)" \
    '[[ $(json "$CONFIG") == "$(expect_json "$LOCAL_URL" "$TOKEN")" ]]'
  yes "config.json is 0600" '[[ $(mode "$CONFIG") == 600 ]]'
  yes "the config directory is 0700" '[[ $(mode "$H/.config/omavikunja") == 700 ]]'
  yes "the token never appears on the terminal" '! has "$TOKEN"'
  yes "the connection check reports success" 'has "the server accepted the token"'
  yes "the server got the token in the Authorization header" \
    'grep -qxF "/api/v2/user Bearer $TOKEN" "$TMP/seen"'
  if [[ -n $REAL_CURL ]]; then
    yes "curl was called" '[[ -s $TMP/argv ]]'
    yes "the token was not in curl's argv" '! grep -qF "$TOKEN" "$TMP/argv"'
  fi
  yes "no clear-text warning for 127.0.0.1" '! has "clear text"'
  yes "nothing is left in HOME but the link and the config" '[[ $(tree) == "$EXPECTED_TREE" ]]'
  yes "registered through omarchy plugin enable" 'grep -q "^omarchy plugin enable cschaba.omavikunja" "$TMP/stubs.log"'
  yes "and omarchy bar put" 'grep -qx "omarchy bar put cschaba.omavikunja" "$TMP/stubs.log"'
  yes "the keybinding is printed, not written" 'has "o.bind(" && [[ ! -e $H/.config/hypr ]]'
  yes "no temporary file is left next to the config" \
    '[[ -z $(find "$H/.config/omavikunja" -name ".config.json.*") ]]'

  # --- a second run ---------------------------------------------------------

  echo
  echo "existing config"
  before="$(sha256sum "$CONFIG" 2>/dev/null || true)"
  if install_tty "https://other.example.com" "tk_other"; then ok "a re-run succeeds"; else bad "a re-run failed"; show_output; fi
  yes "the existing config is reported as kept" 'has "kept the existing"'
  yes "it is not asked for again" '! has "blank to skip"'
  yes "the existing config is byte-for-byte unchanged" '[[ $(sha256sum "$CONFIG") == "$before" ]]'
  yes "and still 0600" '[[ $(mode "$CONFIG") == 600 ]]'
  if command -v jq >/dev/null 2>&1; then
    yes "the re-run checks the connection with what is in the file" 'has "the server accepted the token"'
  else
    skip "jq unavailable — the re-run's connection check is not tested"
  fi

  chmod 644 "$CONFIG"
  install_batch || true
  yes "a config readable by others is warned about" 'has "it is mode 644"'
  yes "but its mode is left as the user set it" '[[ $(mode "$CONFIG") == 644 ]]'
fi

# --- fresh install, not interactive ------------------------------------------

echo
echo "fresh install, not interactive"
fresh_home
if install_batch; then ok "install.sh succeeds with no terminal"; else bad "install.sh failed"; show_output; fi
yes "the defaults are written" '[[ $(json "$CONFIG") == "$(expect_json "" "")" ]]'
yes "config.json is 0600" '[[ $(mode "$CONFIG") == 600 ]]'
yes "the config directory is 0700" '[[ $(mode "$H/.config/omavikunja") == 700 ]]'
yes "it says where to fill them in" 'has "Fill in what is still empty" && has "$CONFIG"'
yes "no connection is attempted without a URL" '[[ ! -s $TMP/argv ]]'
yes "nothing is left in HOME but the link and the config" '[[ $(tree) == "$EXPECTED_TREE" ]]'

echo
echo "blank answers"
fresh_home
if install_tty "" ""; then ok "install.sh succeeds"; else bad "install.sh failed"; show_output; fi
yes "blank answers write the defaults" '[[ $(json "$CONFIG") == "$(expect_json "" "")" ]]'
yes "and say where to fill them in" 'has "Fill in what is still empty"'

# --- invalid answers ---------------------------------------------------------

echo
echo "invalid URL"
fresh_home
install_tty "ftp://vikunja.example.com" 'https://vikunja.example.com/"x' 'https://vikunja.example.com\x' \
  "vikunja.example.com" "" "" || true
yes "each invalid URL is refused" '[[ $(grep -c "is not an http:// or https:// URL" "$TMP/out") == 4 ]]'
yes "and none of them reaches the file" '[[ $(json "$CONFIG") == "$(expect_json "" "")" ]]'

echo
echo "invalid token"
fresh_home
install_tty "https://127.0.0.1:9" 'tk_bad"quote' "nottk_example" "tk_" "tk_spa ce" "" || true
yes "each invalid token is refused" '[[ $(grep -c "is not a Vikunja API token" "$TMP/out") == 4 ]]'
yes "a refused token is not repeated back" '! has "tk_bad" && ! has "nottk_example"'
yes "the URL is kept and the token left empty" \
  '[[ $(json "$CONFIG") == "$(expect_json "https://127.0.0.1:9" "")" ]]'
yes "valid JSON all the same" 'json "$CONFIG" >/dev/null'

# --- the network -------------------------------------------------------------

echo
echo "plain http to another host"
fresh_home
# .invalid never resolves (RFC 6761), so the check fails fast and offline.
if install_tty "http://vikunja.invalid" "$TOKEN"; then ok "install.sh succeeds — a warning, not a refusal"; else bad "install.sh failed"; show_output; fi
yes "it warns that the token would travel in clear text" 'has "clear text"'
yes "the URL is written as given" '[[ $(json "$CONFIG") == "$(expect_json "http://vikunja.invalid" "$TOKEN")" ]]'
yes "the token never appears on the terminal" '! has "$TOKEN"'

for url in "http://localhost:9" "http://[::1]:9"; do
  fresh_home
  install_tty "$url" "$TOKEN" || true
  yes "no warning for $url" '! has "clear text"'
done

echo
echo "unreachable server"
if [[ -z $REAL_CURL ]]; then
  skip "curl unavailable — skipped the connection check"
else
  fresh_home
  # Nothing listens on the discard port.
  if install_tty "https://127.0.0.1:9" "$TOKEN"; then ok "install.sh still succeeds"; else bad "install.sh failed"; show_output; fi
  yes "it says the server could not be reached" 'has "could not reach the server"'
  yes "the token never appears in the output" '! has "$TOKEN"'
  yes "the token was not in curl's argv" '! grep -qF "$TOKEN" "$TMP/argv"'
  yes "the config is written all the same" '[[ -f $CONFIG ]]'

  echo
  echo "token refused"
  if [[ -n $PORT ]]; then
    fresh_home
    install_tty "$LOCAL_URL" "tk_wrong" || true
    yes "a 401 is reported as a refused token" 'has "the token was refused"'
    yes "the token never appears in the output" '! has "tk_wrong"'
  fi
fi

# --- uninstall ---------------------------------------------------------------

echo
echo "uninstall"
fresh_home
install_batch || true
mkdir -p "$H/.local/state/omavikunja"
touch "$H/.local/state/omavikunja/cache.json"

run_env bash "$ROOT/uninstall.sh" --help >"$TMP/out" 2>&1 || true
yes "--help says --purge deletes the API token" 'has "--purge" && has "API token"'

run_env bash "$ROOT/uninstall.sh" </dev/null >"$TMP/out" 2>&1 || bad "uninstall.sh failed"
yes "a plain uninstall removes the link" '[[ ! -e $H/.config/omarchy/plugins/cschaba.omavikunja ]]'
yes "and keeps the config" '[[ -f $CONFIG ]]'
yes "and says so" 'has "kept $H/.config/omavikunja, with your API token"'
yes "it unregisters through omarchy plugin disable" 'grep -qx "omarchy plugin disable cschaba.omavikunja" "$TMP/stubs.log"'

run_env bash "$ROOT/uninstall.sh" --purge </dev/null >"$TMP/out" 2>&1 || bad "uninstall.sh --purge failed"
yes "--purge removes ~/.config/omavikunja" '[[ ! -e $H/.config/omavikunja ]]'
yes "--purge removes ~/.local/state/omavikunja" '[[ ! -e $H/.local/state/omavikunja ]]'
yes "--purge says the token is still valid in Vikunja" 'has "still valid"'
yes "the checkout is untouched" '[[ -f $ROOT/install.sh && -f $ROOT/manifest.json ]]'

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
