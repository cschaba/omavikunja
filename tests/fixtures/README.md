# Recorded Vikunja API v2 responses

Real answers from **Vikunja v2.7.0** (the linux-amd64 release binary, SQLite),
recorded on 2026-10-20 by `tests/integration/run.sh` against a throwaway local
server, a throwaway account and a throwaway token. They are what the API
client's tests run against instead of a live server.

| File | Request |
|---|---|
| `info.json` | `GET /api/v2/info` |
| `user.json` | `GET /api/v2/user` |
| `tasks-page-1.json`, `tasks-page-2.json` | `GET /api/v2/tasks?filter=done%3Dfalse&sort_by=due_date&order_by=asc&page=N&per_page=25` — 55 open tasks, 3 pages |
| `projects.json` | `GET /api/v2/projects` — the automatic Inbox plus Home and Work |
| `error-401.json` | `GET /api/v2/tasks` with an unknown token |

Scrubbed: the server address is `https://vikunja.example.com`, the account is
`demo`. No token appears in any of them.

Due dates were relative to the recording ("overdue" is two days before it), so
a test must compare against the dates in the file, never against today.

To refresh them, run `tests/integration/run.sh <out-dir>` against a throwaway
Vikunja, or download the `vikunja-v2-fixtures-latest` artifact from the
integration workflow, and copy `<out-dir>/fixtures/*.json` here.
