# Fixtures

Real Vikunja API v2 response bodies, byte for byte as the server sent them, for
the tests of `Vikunja.js`. Recorded on 2026-10-20 from the v2.7.0 release
binary running locally with SQLite, with a throwaway user (`demo`) and an API
token holding exactly the scopes in the README. `error-404-info-v2.3.0.json`
comes from v2.3.0, the release before API v2.

Only the body is stored; the status is in the table, and a test hands both to
the parser as `{status, body}` — the shape `send()` produces.

| File | Request | Status |
|---|---|---|
| `info.json` | `GET /api/v2/info` (no token) | 200 |
| `user.json` | `GET /api/v2/user` | 200 |
| `tasks-open-page-1.json` | `GET /api/v2/tasks?filter=done%3Dfalse&sort_by=due_date&order_by=asc&page=1&per_page=50` | 200 |
| `tasks-open-page-2.json` | the same, `page=2` | 200 |
| `projects.json` | `GET /api/v2/projects?page=1&per_page=50` | 200 |
| `error-401-invalid-token.json` | `GET /api/v2/user` with a made-up token | 401 |
| `error-404-task.json` | `GET /api/v2/tasks/99999` | 404 |
| `error-404-unknown-route.json` | `GET /api/v2/nope` | 404 |
| `error-422-validation.json` | `POST /api/v2/projects/1/tasks` `{"title": ""}` | 422 |
| `error-404-info-v2.3.0.json` | `GET /api/v2/info` on Vikunja 2.3.0 | 404 |

What the data covers:

- **57 open tasks over two pages** (`total_pages: 2`, 50 + 7), so the page walk
  is exercised. Two done tasks exist on the server and are absent here.
- **Due dates:** two overdue, 19 in the future, 36 with no due date
  (`0001-01-01T00:00:00Z`), which sort after every dated task. "Overdue" is
  relative to the recording day: compare against a fixed date, never `now`.
- **Priority ≥ 3:** "Pay the electricity bill" (4, overdue), "Prepare the
  workshop" (3), "Buy milk" (5, no due date).
- **Projects:** Inbox (1, the default project), Home (2), Work (3), and a
  saved filter "Urgent" as id `-2`, which `total` does not count.
- **User:** `default_project_id: 1`, `frontend_settings: null` — a user who
  never opened the web app's settings.

There is no token in any of these files, and no host but `127.0.0.1` and
`localhost`. Keep it that way when re-recording: start a local server, create
a throwaway user and token, and grep the files for `tk_` before committing.
