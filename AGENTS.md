# Working on OmaVikunja

Conventions for anyone — human or agent — making changes here. [CLAUDE.md](CLAUDE.md)
is a pointer to this file. The reasoning behind the code is in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Where things stand

OmaVikunja is an **Omarchy plugin** (Quickshell/QML, loaded by `omarchy-shell`)
— a bar widget that lists your open [Vikunja](https://vikunja.io) tasks,
quick-adds one, marks one done, and opens one in the browser.

**It is a scaffold.** `BarWidget.qml` loads and opens an empty pulldown;
`install.sh`, `uninstall.sh`, `scripts/release.sh`, `tests/smoke.sh` and the two
workflows are ported from omaipsum and work. Nothing talks to Vikunja yet. The
plan is on GitHub as milestones and issues — the tracker holds what is not
durable, so no issue count is written down here.

## Where it lives

- **`origin`** — `git@github.com:cschaba/omavikunja.git`, public. Code, issues,
  milestones, releases and CI. **Everything happens here.**
- **`gitea`** — `ssh://gitea@gitea.s10r.de:2811/carsten/omavikunja.git`,
  private. A backup of the code: pushed to, never worked in, never read from.
  File no issues there. (omaipsum's AGENTS.md records why: that Gitea has no
  Actions runner.)

## The sibling plugins are the reference

`~/Projects/omaipsum` (`cschaba/omaipsum`) and `~/Projects/omapass`
(`cschaba/omapass`) are the same author's finished Omarchy plugins. Most of this
repository was copied from omaipsum; its `AGENTS.md` and `docs/` hold far more
detail than this file — the marketplace checklist, what the marketplace scanner
reads, Quickshell traps. omapass is the reference for an **overlay** and for
handling a **secret**, both of which this plugin will need.

Copy from them, but read what you copy: anything with no reason to exist here
comes out.

## An issue is scaffolding, the code is the building

Before implementation an issue is the most valuable document there is.
Afterwards it must not be the only place that knowledge lives: the code is
commented for the trap and the constraint, and *why* a choice beat the obvious
alternative moves into [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Close the
tracker, and nothing is lost but history.

## Branches, commits, releases

- **One branch per issue**: `issue/<number>-<slug>` off `main`, merged back with
  `git merge --no-ff`. `main` stays releasable. Release bookkeeping and
  untracked doc fixes go to `main` directly.
- **Commits**: authored `Carsten <carsten@s10r.de>`, with a `Co-Authored-By:`
  trailer where that applies. Close issues with `Fixes #N` in the body.
  **Never write a closing keyword with `#N` anywhere else** — not even to deny
  it; GitHub does not read the sentence around it. Use `Refs #N`.
- **Changelog**: add the entry under `[Unreleased]` as part of the fix.
- **Releases**: `scripts/release.sh patch|minor` after merging. It runs the
  tests, bumps `manifest.json` (the only place the version lives), moves the
  changelog entry, tags and pushes to `origin`, then mirrors to `gitea`. The
  tag triggers `.github/workflows/release.yml`, which publishes the Release.
- **Milestones** are the roadmap: `0.1.0 — read`, `0.2.0 — write`,
  `0.3.0 — shipping`. A release that completes a milestone closes it.
- **Issues** from the repository owner: fix directly. From anyone else:
  evaluate and hand back options.

## Before you believe a test

- **Restart the shell after changing any QML** — `omarchy restart shell`.
  `omarchy-shell` loads plugin QML once; `rescanPlugins` does not follow a
  symlinked checkout.
- **A bar widget must publish its own implicit size**, or it gets a 0×0 slot
  and renders nothing, with no error.
- **Plugin load errors can be swallowed.** omapass's `DEVELOPMENT.md` has the
  recipe for loading a file in a throwaway Quickshell config to see the real
  message.

## Commands

```bash
./install.sh                                    # symlink the checkout in and register
omarchy restart shell                           # the only reliable QML reload
omarchy-shell cschaba.omavikunja.widget toggle  # open the pulldown
journalctl --user -f | grep omarchy-shell       # where QML errors land
tests/smoke.sh                                  # manifest, schema, QML, scripts
scripts/release.sh patch --dry-run              # what a release would do
qmllint -I /usr/share/omarchy/shell *.qml       # type checking, locally
```

## Use the Omarchy API

Omarchy already does most of this — look before building.

| Need | Use |
|------|-----|
| Enable, disable, list a plugin | `omarchy plugin …` |
| Place a widget, set an option | `omarchy bar …` |
| Open, close, toggle a surface | `omarchy-shell shell summon\|hide\|toggle <id>` |
| Desktop notification | `omarchy-notification-send` |
| Open a URL | `omarchy-launch-browser` |
| Colours, fonts, spacing | `Color`, `Style`, `Border` from `qs.Commons` — never a literal |
| Bar button with a popup | `Panel`, `BarIconButton`, `KeyboardPanel`, `PanelKeyCatcher` from `qs.Ui` |
| Text input | `TextField` from `qs.Ui` |

`/usr/share/omarchy/shell/plugins/README.md` documents the plugin contract;
`panels/weather` and `panels/tailscale` are worked examples of a widget that
polls a service.

## Talking to Vikunja

Three decisions bind every change; the reasoning and the verified API facts are
in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

1. **Configuration is one file**, `~/.config/omavikunja/config.json`
   (`0600`): server URL, API token, and every later option. Not `shell.json`,
   not the manifest schema. `install.sh` asks for URL and token; the plugin
   writes defaults if the file is missing.
2. **API v2 only** (Vikunja ≥ 2.4.0). Lists come wrapped in
   `{items, total, page, per_page, total_pages}`; partial updates use `PATCH`.
   Never fall back to v1.
3. **HTTP is `XMLHttpRequest` in `Vikunja.js`**, no dependencies: pure
   request/response functions testable under node, one `send()` doing I/O.

And two traps:

- **Quick Add Magic is parsed by the web frontend, not the server.** A title
  sent as `buy milk *home !3 tomorrow` is stored literally.
- **No due date is `0001-01-01T00:00:00Z`**, not `null`.

Never put a real token in a test, a fixture, a log line, a notification, a
command line or a commit. Tests run against recorded fixtures, not a live
server.

## Stay inside the plugin

OmaVikunja never creates, edits or deletes a file outside its own directories:
the plugin directory, `~/.config/omavikunja/` and `~/.local/state/omavikunja/`.
Everything else — `~/.config/hypr/bindings.lua`, `~/.config/omarchy/shell.json`
— belongs to the user. Where something outside has to change, print the exact
line and stop. Omarchy's own commands (`omarchy plugin enable`, `omarchy bar
put`) are the exception, because they are what a user would type.

Unlike omaipsum, this plugin **uses the network and holds a secret**. Both are
things the marketplace scan and a careful user will look for; keep them to the
one configured server URL and the one config file holding the token, and say so in the README.
