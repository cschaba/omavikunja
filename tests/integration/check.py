"""Checks the Vikunja API v2 facts OmaVikunja relies on, against a live server.

Run by tests/integration/run.sh, never by hand against a real instance: it
registers a throwaway user, gives it an API token with exactly the scopes the
README lists, seeds projects and tasks, and then asks the questions
docs/ARCHITECTURE.md answers from memory — the envelope, pagination, the
no-due-date sentinel, PATCH leaving other fields alone, Quick Add Magic being
stored literally, the error body. A Vikunja release that changes any of them
fails here first, not in the bar.

What it answers is written, scrubbed, to <out>/fixtures/: the recorded responses
the API client's node tests (#13) run against. The token goes to <out>/token,
0600, for later steps; it is never printed.

Usage: python3 -I check.py <server-url> <out-dir>
"""

import json
import math
import os
import secrets
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

BASE = sys.argv[1].rstrip("/")
OUT = sys.argv[2]
FIXTURES = os.path.join(OUT, "fixtures")

# The scopes the README tells users to give their token. Seeding and checking
# with exactly these is what proves the README's list is enough.
SCOPES = {
    "tasks": ["read_all", "read_one", "create", "update"],
    "projects": ["read_all"],
    "other": ["user"],
}

NO_DUE_DATE = "0001-01-01T00:00:00Z"
PER_PAGE = 25
FILLER = 50

# No proxy, ever: this talks to a server on this machine, and a token sent
# through a proxy is a token the proxy has seen.
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

SECRETS = []
FAILED = []


def mask(value):
    """Keep a secret out of every log line and every fixture."""
    SECRETS.append(value)
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print("::add-mask::" + value, flush=True)


def call(method, path, body=None, auth=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(BASE + path, data=data, method=method)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    if auth:
        request.add_header("Authorization", "Bearer " + auth)
    try:
        with OPENER.open(request, timeout=15) as response:
            status, headers, text = response.status, response.headers, response.read().decode()
    except urllib.error.HTTPError as error:
        status, headers, text = error.code, error.headers, error.read().decode()
    try:
        parsed = json.loads(text) if text else None
    except ValueError:
        parsed = None
    return status, headers, parsed, text


def scrub(text):
    for value in SECRETS:
        text = text.replace(value, "<redacted>")
    return text


def need(what, status, text, ok=(200, 201)):
    """A setup step that has to work, or nothing after it means anything."""
    if status not in ok:
        sys.exit("setup failed: %s answered %s: %s" % (what, status, scrub(text)[:500]))


def check(label, got, want):
    if got == want:
        print("  ✓ " + label)
    else:
        print("  ✗ %s\n      got:  %s\n      want: %s" % (label, scrub(repr(got))[:300], want))
        FAILED.append(label)


def yes(label, condition):
    check(label, bool(condition), True)


def stamp(delta):
    return (datetime.now(timezone.utc) + delta).strftime("%Y-%m-%dT%H:%M:%SZ")


# --- a throwaway account -------------------------------------------------------
#
# Registration, login and token creation are account plumbing the plugin never
# does, so they go through v1, where they have lived for years. Everything the
# plugin itself does below goes through v2 with the API token, as it will.

print("setup")
username = "omavikunja-ci-" + secrets.token_hex(4)
email = username + "@example.com"
password = secrets.token_urlsafe(18)
mask(password)

status, _, _, text = call("POST", "/api/v1/register",
                          {"username": username, "email": email, "password": password})
need("POST /api/v1/register", status, text)

status, _, body, text = call("POST", "/api/v1/login", {"username": username, "password": password})
need("POST /api/v1/login", status, text)
jwt = body["token"]
mask(jwt)

status, _, body, text = call("PUT", "/api/v1/tokens", {
    "title": "omavikunja-ci",
    "expires_at": stamp(timedelta(days=1)),
    "permissions": SCOPES,
}, auth=jwt)
if status not in (200, 201):
    # The likeliest cause is a scope name that moved; the server lists them.
    _, _, routes, _ = call("GET", "/api/v1/routes", auth=jwt)
    if isinstance(routes, dict):
        print("  scopes this server offers: " + json.dumps(
            {group: sorted(scopes) for group, scopes in routes.items()
             if group in SCOPES and isinstance(scopes, dict)}))
need("PUT /api/v1/tokens", status, text)
token = body["token"]
mask(token)
check("the API token looks like the installer expects (tk_…)", token.startswith("tk_"), True)

os.makedirs(FIXTURES, exist_ok=True)
fd = os.open(os.path.join(OUT, "token"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(token + "\n")

# Projects through v1 with the login session: creating one is not something the
# plugin does, and the token deliberately cannot.
projects = {}
for title in ("Home", "Work"):
    status, _, body, text = call("PUT", "/api/v1/projects", {"title": title}, auth=jwt)
    need("PUT /api/v1/projects", status, text)
    projects[title] = body["id"]
print("  ✓ user, token and projects created")


# --- tasks, created the way the plugin creates them ----------------------------

def create(project, **task):
    status, _, body, text = call("POST", "/api/v2/projects/%d/tasks" % projects[project], task, auth=token)
    need("POST /api/v2/projects/{id}/tasks", status, text, ok=(201,))
    return body


undated = create("Home", title="No due date")
overdue = create("Work", title="Overdue", due_date=stamp(timedelta(days=-2)))
future = create("Work", title="Due next week", due_date=stamp(timedelta(days=7)))
urgent = create("Home", title="Urgent", priority=4)
magic = create("Home", title="buy milk *home !3 tomorrow")
to_finish = create("Work", title="Finish me", description="keep me", priority=2)
for n in range(1, FILLER + 1):
    create("Home" if n % 2 else "Work", title="Filler %02d" % n,
           **({"due_date": stamp(timedelta(days=n))} if n % 3 == 0 else {}))
OPEN = 5 + FILLER  # every task above except the one marked done below
print("  ✓ %d tasks created" % (OPEN + 1))


# --- the facts docs/ARCHITECTURE.md relies on ----------------------------------

fixtures = {}

print("\n/api/v2/info")
status, _, info, text = call("GET", "/api/v2/info")
fixtures["info"] = text
check("answers 200 without authentication", status, 200)
yes("has a version", isinstance(info, dict) and info.get("version"))
yes("has a frontend_url ending in /", isinstance(info, dict) and str(info.get("frontend_url", "")).endswith("/"))
yes("has max_items_per_page", isinstance(info, dict) and "max_items_per_page" in info)
print("  · Vikunja %s" % (info or {}).get("version"))

print("\n/api/v2/user")
status, _, user, text = call("GET", "/api/v2/user", auth=token)
fixtures["user"] = text
check("answers 200 to a token with other:user", status, 200)
yes("has settings.default_project_id as a number",
    isinstance(((user or {}).get("settings") or {}).get("default_project_id"), int))

print("\nPATCH /api/v2/tasks/{id}")
status, _, done, text = call("PATCH", "/api/v2/tasks/%d" % to_finish["id"], {"done": True}, auth=token)
check("marking done answers 200", status, 200)
done = done or {}
check("the task comes back done", done.get("done"), True)
check("its description is untouched", done.get("description"), "keep me")
check("its priority is untouched", done.get("priority"), 2)

print("\nQuick Add Magic")
check("the server stores the title literally", magic.get("title"), "buy milk *home !3 tomorrow")
check("and sets no priority from it", magic.get("priority"), 0)
check("and no due date", magic.get("due_date"), NO_DUE_DATE)

print("\n/api/v2/tasks")
pages = math.ceil(OPEN / PER_PAGE)
items = []
for page in range(1, pages + 1):
    status, headers, envelope, text = call(
        "GET", "/api/v2/tasks?filter=done%%3Dfalse&sort_by=due_date&order_by=asc&page=%d&per_page=%d"
        % (page, PER_PAGE), auth=token)
    if page <= 2:
        fixtures["tasks-page-%d" % page] = text
    check("page %d answers 200" % page, status, 200)
    envelope = envelope if isinstance(envelope, dict) else {}
    if page == 1:
        check("the list is an envelope with items, total, page, per_page, total_pages",
              sorted(k for k in envelope if not k.startswith("$")),
              ["items", "page", "per_page", "total", "total_pages"])
        check("total counts the open tasks only", envelope.get("total"), OPEN)
        check("total_pages is more than one", envelope.get("total_pages"), pages)
        check("per_page is what was asked for", envelope.get("per_page"), PER_PAGE)
        check("no pagination headers, unlike v1", headers.get("x-pagination-total-pages"), None)
    check("page %d says it is page %d" % (page, page), envelope.get("page"), page)
    expected = min(PER_PAGE, OPEN - (page - 1) * PER_PAGE)
    check("page %d holds %d tasks" % (page, expected), len(envelope.get("items") or []), expected)
    items.extend(envelope.get("items") or [])

ids = [t.get("id") for t in items]
check("every open task is listed exactly once", sorted(ids), sorted(set(ids)))
yes("the done task is not listed", to_finish["id"] not in ids)
by_id = {t.get("id"): t for t in items}
check("no due date is the zero time, not null", (by_id.get(undated["id"]) or {}).get("due_date"), NO_DUE_DATE)
dues = [t.get("due_date") for t in items]
dated = [d for d in dues if d != NO_DUE_DATE]
check("dated tasks come first, oldest first", dues[:len(dated)], sorted(dated))
yes("and the undated ones after them", all(d == NO_DUE_DATE for d in dues[len(dated):]))
yes("the overdue task is first", items and items[0].get("id") == overdue["id"])
check("priority comes through", (by_id.get(urgent["id"]) or {}).get("priority"), 4)
yes("the future task is listed", future["id"] in ids)

print("\n/api/v2/projects")
status, _, envelope, text = call("GET", "/api/v2/projects", auth=token)
fixtures["projects"] = text
check("answers 200 to a token with projects:read_all", status, 200)
envelope = envelope if isinstance(envelope, dict) else {}
yes("is an envelope with items", isinstance(envelope.get("items"), list))
titles = {p.get("title"): p.get("id") for p in envelope.get("items") or []}
check("lists the seeded projects", {t: titles.get(t) for t in projects}, projects)

print("\nerrors")
status, _, error, text = call("GET", "/api/v2/tasks", auth="tk_invalid0000000000")
fixtures["error-401"] = text
check("an unknown token answers 401", status, 401)
yes("with a numeric Vikunja code", isinstance((error or {}).get("code"), int))
yes("and a message", isinstance((error or {}).get("message"), str))


# --- fixtures ---------------------------------------------------------------
#
# Scrubbed of everything that names this run: the server address becomes the
# repository's placeholder host, the throwaway account becomes "demo". The
# secrets were never in a response; they are looked for anyway.

print("\nfixtures")
replacements = [(BASE + "/", "https://vikunja.example.com/"), (BASE, "https://vikunja.example.com"),
                (email, "demo@example.com"), (username, "demo")]
leaks = []
for name, text in sorted(fixtures.items()):
    for old, new in replacements:
        text = text.replace(old, new)
    try:
        text = json.dumps(json.loads(text), indent=2, ensure_ascii=False) + "\n"
    except ValueError:
        pass
    for marker in SECRETS + ["localhost", "127.0.0.1", "omavikunja-ci-"]:
        if marker in text:
            leaks.append(name)
            break
    else:
        with open(os.path.join(FIXTURES, name + ".json"), "w", encoding="utf-8") as f:
            f.write(text)
check("no fixture names the server, the account or a secret", leaks, [])
print("  · written to " + FIXTURES)

print("\n%s" % ("all checks pass" if not FAILED else "%d check(s) failed" % len(FAILED)))
sys.exit(1 if FAILED else 0)
