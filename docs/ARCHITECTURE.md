# Architecture and decisions

Why OmaVikunja is shaped the way it is. Each decision records the options it
beat; the code only shows the winner.

## Vikunja API

Verified on 2026-09-16 against try.vikunja.io (Vikunja v2.6.0, released
2026-08-31) and its swagger at `/api/v1/docs.json`. Re-check before relying on
anything marked *unverified*.

### Versions: v1 and v2

Vikunja 2.4.0 introduced **API v2** (<https://vikunja.io/docs/api-v2/>). v1 is
frozen, planned for deprecation in v3.0 and removal in v4.0 (the docs' own
estimates: late 2026 and late 2027). v2 creates with `POST`, replaces with
`PUT`, supports `PATCH` (JSON Merge Patch), and wraps lists as
`{items, total, page, per_page, total_pages}`. Authentication is the same.

*Unverified:* the exact envelope and filter support of `GET /api/v2/tasks`, and
whether Vikunja Cloud serves v2 (its `/info` reports a commit hash, not a
version).

### Authentication

- API tokens: created under *Settings → API Tokens*, prefixed `tk_`, sent as
  `Authorization: Bearer <token>`. Scopes are per group; `GET /api/v1/routes`
  lists them.
- Scopes this plugin needs: `tasks: read_all, read_one, create, update`,
  `projects: read_all`, `other: user`. Without `other: user`, `/user` is a 401.
- Vikunja Cloud does not support password login — tokens are the only way in.
  API base `https://app.vikunja.cloud/api/v1`.

### Endpoints

| Purpose | Request | Notes |
|---|---|---|
| Connection check | `GET /api/v1/info` | No auth. `version`, `frontend_url`, `max_items_per_page` (default 50). |
| Current user | `GET /api/v1/user` | `settings.default_project_id` (may be 0). |
| My open tasks | `GET /api/v1/tasks?filter=done%3Dfalse&sort_by=due_date&order_by=asc&page=N&per_page=N` | All accessible projects, not only assigned tasks. `/tasks/all` was removed in 1.0.0 and returns 400. Pagination in `x-pagination-total-pages`. |
| Create a task | `PUT /api/v1/projects/{id}/tasks` · v2: `POST /api/v2/projects/{id}/tasks` | Only `title` required. |
| Mark done | v2: `PATCH /api/v2/tasks/{id}` `{"done":true}` | **v1 `POST /api/v1/tasks/{id}` replaces the whole task** — a partial body wipes description and priority. |
| Web link | `{frontend_url}/tasks/{id}`, `{frontend_url}/projects/{id}` | Base from `/info`. |

### Gotchas

- **No due date** comes back as `0001-01-01T00:00:00Z`, not `null`.
- **Quick Add Magic is frontend-only.** The server stores
  `probe *urgent !4 tomorrow` literally. The parser lives in Vikunja's
  `frontend/src/modules/quickAddMagic/`; supporting the syntax means porting
  it.
- **Errors** carry a Vikunja `code` in the JSON body; check it as well as the
  HTTP status.
- **Rate limiting** is off by default; when enabled, 100 requests / 60 s per
  user, with `X-RateLimit-*` headers. *Unverified* whether Cloud enables it.
- CORS does not apply: this is not a browser.

## Open decisions

Tracked as issues until decided, then recorded here with the reasoning.

- Where the API token is stored (a `0600` file under `~/.config/omavikunja/`,
  `pass` as omapass does, or the Secret Service keyring).
- API v2 only (requires Vikunja ≥ 2.4) or v1 with a v2 upgrade path.
- HTTP from QML (`XMLHttpRequest`) or a small helper script run via `Process`.
