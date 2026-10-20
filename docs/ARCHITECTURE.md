# Architecture and decisions

Why OmaVikunja is shaped the way it is. Each decision records the options it
beat; the code only shows the winner.

## Decisions

### 1. One config file holds the connection and the plugin's options (#1)

**Decided:** everything OmaVikunja needs to know lives in one file,

```
${XDG_CONFIG_HOME:-~/.config}/omavikunja/config.json
```

```json
{
  "schemaVersion": 1,
  "serverUrl": "https://vikunja.example.com",
  "apiToken": "tk_…",
  "refreshIntervalSec": 300
}
```

New options are added to this file, not to the manifest's `barWidget.schema`.
Placement on the bar is the only thing left in `~/.config/omarchy/shell.json`,
because Omarchy owns that.

**How the file comes to exist**

- **`install.sh` asks.** When run interactively it prompts for the server URL
  and the API token (read without echo) and writes the file. Run
  non-interactively, or with the answers left blank, it writes the defaults and
  prints where to fill them in. It never overwrites an existing config.
- **The plugin creates a default on first run** if the file is missing — for
  installs through `omarchy plugin add`, which never runs `install.sh`. The
  pulldown then says what to fill in and where.
- **Permissions:** the directory is created `0700` and the file `0600`, by
  whichever of the two creates it. The token is the only secret the plugin
  holds, and a token with `tasks:update` can change every task the user can
  see.
- **`uninstall.sh --purge`** removes the directory; a plain uninstall keeps it.

**Why a file of our own, and not the alternatives**

- *`shell.json` widget settings* (the scaffold's first draft) — owned by
  Omarchy, often committed to dotfile repositories, and not a place for a
  secret. Splitting the URL there and the token elsewhere would leave the
  connection in two places.
- *`pass`*, as omapass does — encrypted at rest, but it adds GPG and a possible
  pinentry prompt at shell start for a token that is revocable in Vikunja in
  one click.
- *Secret Service* (`secret-tool`) — not present on every Omarchy install.

**Rules that follow from it**

- The token is never logged, shown, put in a notification, or passed on a
  command line (argv is visible to every process). The installer's optional
  connection check passes it to `curl` on stdin, not as an argument.
- The file is JSON so QML reads it with `JSON.parse` and the installer writes
  it without `jq` or `python3`. The installer validates the values before
  writing: the token must match `^tk_[A-Za-z0-9]+$`, and the URL must be
  `http(s)://` with no quotes or backslashes, so plain `printf` cannot produce
  broken JSON.
- A missing key falls back to the default above; an unknown `schemaVersion` is
  reported rather than guessed at.

### 2. Vikunja API v2 only (#2)

**Decided:** the client speaks **API v2** and nothing else. Minimum server:
**Vikunja 2.4.0**, the release that introduced v2
(<https://vikunja.io/docs/api-v2/>). Vikunja Cloud serves v2 — verified
2026-09-17: `GET https://app.vikunja.cloud/api/v2/info` answers `200`, and
`/api/v2/tasks` answers `401` rather than `404`.

**Why not v1**

- v1 is frozen, deprecated from v3.0 and removed in v4.0 (the docs' own
  estimates: late 2026 and late 2027). A plugin started now would have to be
  ported within a year.
- v1 cannot update part of a task. `POST /api/v1/tasks/{id}` replaces the whole
  task: sending `{"done": true}` wiped the description and reset the priority
  on try.vikunja.io. Marking a task done would need a read, an edit and a
  write-back, which overwrites anything changed elsewhere in between. v2's
  `PATCH` sends only the field that changes.
- One API means one response shape to parse and one set of fixtures to test.

The cost is that self-hosted servers older than 2.4.0 are not supported. The
connection check (`GET /api/v2/info`) fails with a clear message on them rather
than half-working.

### 3. HTTP from a plain JavaScript library, no dependencies (#3)

**Decided:** the API client is one JavaScript file, `Vikunja.js`, imported by
QML (`.pragma library`) and using the `XMLHttpRequest` built into Qt's QML
engine. No npm packages, no `curl`, no helper script, no process spawned per
request.

Verified 2026-09-17 against Qt 6.11.2 (the Qt Quickshell 0.3.1 runs on here):
QML's `XMLHttpRequest` sends `GET`, `POST`, `PUT`, `PATCH` and `DELETE`, with
an `Authorization` header and a JSON body, to a local echo server.

**Keep it simple — the shape of the file**

- *Pure functions* build requests (method, URL, headers, body) and turn
  responses into plain objects or one error shape
  (`{kind, status, code, message}`). They touch no network and no QML, so they
  run unchanged under `node` in `tests/` against recorded JSON fixtures.
- *One small `send()`* wraps `XMLHttpRequest` and is the only code that does
  I/O. Tests replace it; nothing else needs mocking.
- No classes, no promises library, no build step — the file QML imports is the
  file in the repository.

**Why not the alternative:** a `curl` + `jq` helper run through `Process` is
easy to try in a terminal, but it adds two runtime dependencies, starts a
process for every request, and makes it easy to leak the token through argv.

Timeouts: whether Qt's `XMLHttpRequest` honours the `timeout` property is
*unverified*. `send()` sets it anyway, and every call returns `{abort}`, so if
Qt ignores it the widget pairs the call with a QML `Timer` and calls `abort()`.
A `.pragma library` script has no `setTimeout` to do that itself.

**How the client came out (#4)**

- *Exports.* Pure: `serverBase`, `apiUrl`, `checkConfig`, `infoRequest`,
  `currentUserRequest`, `openTasksRequest`, `projectsRequest`,
  `describeRequest`, `parseInfo`, `parseCurrentUser`, `parseEnvelope`,
  `normaliseTask`, `normaliseDueDate`, `projectTitles`, `toError`,
  `makeError`, `redact`, `parseVersion`. I/O: `send`. What the widget calls:
  `info`, `currentUser`, `openTasks`, `projects`, each
  `(config, callback(error, value))` → `{abort}`, where `config` is the
  parsed `config.json`.
- *Callbacks, not promises.* A callback is what `XMLHttpRequest` gives, and
  it runs the same in QML's engine and under node with nothing to schedule.
  Node-style `(error, value)` keeps one shape for all four calls.
- *Error kinds.* `config`, `network`, `timeout`, `aborted`, `unsupported`,
  `auth`, `forbidden`, `notFound`, `rateLimited`, `server`, `client`,
  `parse`. The widget picks wording or an action by `kind`; `message` is
  already fit to show. Vikunja's code 11 (invalid token) is `auth` whatever
  the status.
- *The token stays in `request.headers`.* No message is built from it, and
  every message also passes through `redact()`, which blanks `tk_…` and
  `Bearer …` in case a server echoes a header back. `describeRequest()` is the
  way to log a request: method and URL, no headers.
- *`/info` is sent without the token.* It needs none, and until it answers
  nothing says the configured URL is a Vikunja server.
- *"No API v2" has more than one face.* Vikunja 2.3.0 answers
  `/api/v2/info` with a `404` and `{"message":"Not Found"}` (verified, see
  below). A reverse proxy whose catch-all serves the web app could turn that
  into a `200` of `index.html` instead. Both, an answer with no `version`, and
  a version below 2.4.0 all come out as `unsupported`. A version that is not
  `x.y.z` (Cloud's commit hash) is accepted.
- *`serverUrl` is forgiving.* Trailing slashes go, and so does a trailing
  `/api/v1` or `/api/v2`: Vikunja's settings page shows the API URL with
  `/api/v1` on the end, which is what gets pasted.
- *Paging.* `per_page=50` (Vikunja's default maximum); the walk follows
  `total_pages` one page at a time, stops early on an empty page, and gives up
  after 50 pages so a server that misreports `total_pages` cannot keep it
  going.
- *v2 errors come in two shapes*, so `toError` reads both and never shows a
  raw body: `{code, message}` from the auth middleware, and an RFC 9457
  problem document from the handlers (see Gotchas). A 422's `detail` is only
  "validation failed"; the first entry of `errors[]` is appended to say what
  failed.
- *Under node,* `tests/lib/load-vikunja.js` loads the file into a `vm`
  context; a test replaces `send` by assigning to it. `tests/fixtures/` holds
  real v2 responses recorded for the tests (its README says how).

## Vikunja API v2 reference

Verified on 2026-09-17 against try.vikunja.io (`v2.6.0-378-gce2c0822`) with the
demo account, and Vikunja Cloud's public `/info`. Verified again on 2026-10-20
against a local Vikunja **v2.7.0** (the release binary, SQLite) with an API
token holding exactly the scopes below, and against a local **v2.3.0** for the
"no v2" answer. Re-check anything marked *unverified* before relying on it.

### Authentication

- API tokens are created under *Settings → API Tokens*, start with `tk_`, and
  are sent as `Authorization: Bearer <token>`. Scopes are per group.
- Scopes this plugin needs: `tasks: read_all, read_one, create, update`,
  `projects: read_all`, `other: user`. Without `other: user`, `/user` is a 401.
  v2 routes honour the same scope names: with these scopes `/api/v2/user`,
  `/api/v2/tasks` and `/api/v2/projects` answer `200`, and
  `/api/v2/projects/{id}` (needs `projects: read_one`) answers `401`.
  `/api/v1/routes`, the list the token dialog is built from, names only v1
  paths. `tasks` also offers `read`, which is `POST /tasks/{id}/read`, not
  reading tasks; the plugin does not need it.
- Vikunja Cloud has no password login, so a token is the only way in. Server
  URL `https://app.vikunja.cloud`.

### Envelope

"Envelope" means the wrapper object a list comes back in. v1 returns a bare
JSON array and puts the page counts in response headers
(`x-pagination-total-pages`). **v2 wraps every list in an object and returns no
pagination headers:**

```json
{
  "$schema": "https://try.vikunja.io/api/v2/schemas/PaginatedTask.json",
  "items": [ { "id": 4, "title": "…", "done": false, "due_date": "…", "project_id": 5, "priority": 1 } ],
  "total": 4,
  "page": 1,
  "per_page": 2,
  "total_pages": 2
}
```

Single objects (`/info`, `/user`) are returned directly, with a `$schema` key
added.

### Endpoints

| Purpose | Request | Notes |
|---|---|---|
| Connection check | `GET /api/v2/info` | No auth. `version` (a commit hash on Cloud), `frontend_url`, `max_items_per_page`. |
| Current user | `GET /api/v2/user` | `settings.default_project_id` (may be 0), `settings.frontend_settings.quick_add_magic_mode`. `frontend_settings` is `null` for a user who never opened the web app's settings. No email in the answer. |
| My open tasks | `GET /api/v2/tasks?filter=done%3Dfalse&sort_by=due_date&order_by=asc&page=N&per_page=N` | Enveloped. Every project the user can access, not only assigned tasks. Filter and sort verified. |
| Projects | `GET /api/v2/projects` | Enveloped. **Negative ids are saved filters**, not projects (saved filter 1 comes back as id `-2`); they count towards neither `per_page` nor `total`. |
| Create a task | `POST /api/v2/projects/{id}/tasks` | `201` with the created task. Only `title` is required. |
| Mark done | `PATCH /api/v2/tasks/{id}` `{"done": true}` | `200`; description and priority untouched. Accepts `Content-Type: application/json` as well as `application/merge-patch+json`. |
| Delete a task | `DELETE /api/v2/tasks/{id}` | `204`, empty body. Not used by the plugin; noted for tests. |
| Web link | `{frontend_url}tasks/{id}`, `{frontend_url}projects/{id}` | `frontend_url` from `/info` ends with a `/`. |

### Gotchas

- **No due date** is `"0001-01-01T00:00:00Z"`, not `null`. Sorting by
  `due_date` ascending puts those tasks *after* the dated ones.
- **Quick Add Magic is parsed by the web app only.** The server stores
  `probe *urgent !4 tomorrow` literally; supporting the syntax means
  implementing it here (#11).
- **Errors** carry a Vikunja `code` in the JSON body; check it as well as the
  HTTP status. v2 sends two shapes. A bad or missing token gets the auth
  middleware's `{"code": 11, "message": "missing, malformed, expired or
  otherwise invalid token provided"}` with `401`, and an unknown route
  `{"message": "Not Found"}`. Everything from a handler is an RFC 9457 problem
  document: `{"$schema", "title": "Not Found", "status": 404, "detail": "This
  task does not exist", "code": 4002}`; a `422` adds `"errors": [{"message":
  "expected length >= 1", "location": "body.title", "value": ""}]` and no
  `code`; a `500` says only `"unexpected error occurred"`.
- **Rate limiting** is off by default; when enabled, 100 requests per 60 s per
  user, with `X-RateLimit-*` headers. *Unverified* whether Cloud enables it.
- CORS does not apply: this is not a browser.
