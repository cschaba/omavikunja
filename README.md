# OmaVikunja

Your [Vikunja](https://vikunja.io) tasks from the bar, for
[Omarchy 4](https://omarchy.org).

> **Status: early development.** Nothing is released yet. The roadmap lives in
> the [milestones](https://github.com/cschaba/omavikunja/milestones), and this
> README describes what the plugin is going to do; the
> [changelog](CHANGELOG.md) records what it actually does so far.

Vikunja is an open-source task and project manager, self-hosted or on
[Vikunja Cloud](https://vikunja.cloud). OmaVikunja gives you quick access to it
without opening a browser tab.

## Features

- **List my tasks** — open tasks from every project you can access, overdue
  first, then by due date. The bar icon shows how many are open or overdue.
- **Quick add** — type a title and press Enter. The task lands in your default
  Vikunja project. Vikunja's
  [Quick Add Magic](https://vikunja.io/docs/quick-add-magic/) shorthand
  (`*label`, `+project`, `!priority`, dates like `tomorrow`) is planned.
- **Mark done** — tick a task off straight from the list.
- **Open in the browser** — jump to the selected task, or to Vikunja itself.

Not planned: editing descriptions, managing projects, labels or teams, or
offline sync. For those, open Vikunja.

## Requirements

| | | |
|---|---|---|
| Omarchy 4 | required | It is a shell plugin: `omarchy-shell` loads it and `omarchy` registers it. Omarchy 4 is still in alpha, so the plugin API may change under it. |
| A Vikunja server | required | Self-hosted **2.4.0 or newer**, or Vikunja Cloud. OmaVikunja uses Vikunja's API v2 only, which 2.4.0 introduced. |
| A Vikunja API token | required | Created in Vikunja under *Settings → API Tokens*, with the scopes listed below. |

### Token scopes

| Group | Scopes | Used for |
|---|---|---|
| `tasks` | `read_all`, `read_one`, `create`, `update` | listing, adding and completing tasks |
| `projects` | `read_all` | project names in the list |
| `other` | `user` | finding your default project |

## Install

```bash
omarchy plugin add https://github.com/cschaba/omavikunja.git --enable
```

Or from a clone:

```bash
git clone https://github.com/cschaba/omavikunja.git
cd omavikunja
./install.sh
omarchy restart shell
```

`install.sh` symlinks the checkout into
`~/.config/omarchy/plugins/cschaba.omavikunja` and registers it with
`omarchy plugin enable` and `omarchy bar put`. On the first run it asks for your
server URL and API token (see [Configuration](#configuration)). It is safe to
re-run. It does not edit your Hyprland config; it prints a keybinding for you to
add:

```lua
-- in ~/.config/hypr/bindings.lua
o.bind("SUPER + ALT + V", "Vikunja tasks", "omarchy-shell cschaba.omavikunja.widget toggle")
```

## Configuration

Everything lives in one file, `~/.config/omavikunja/config.json`:

```json
{
  "schemaVersion": 1,
  "serverUrl": "https://vikunja.example.com",
  "apiToken": "tk_…",
  "refreshIntervalSec": 300
}
```

When the file does not exist, `install.sh` asks for the server URL and the
token (the token is not echoed as you type) and writes the file for you:

- The URL must start with `http://` or `https://`; the token looks like
  `tk_` followed by letters and digits. Anything else is asked for again.
- Leave an answer blank, or run the script without a terminal, and that value
  is written empty. The script tells you which file to fill in.
- If `curl` is installed, it then checks the connection with one request to
  `<serverUrl>/api/v2/user` and tells you whether the server accepted the
  token. The script never prints the token.
- A plain `http://` URL to any host other than `localhost`, `127.0.0.1` or
  `::1` gets a warning, because the token would cross the network in clear
  text. The script warns but does not refuse.

`install.sh` never overwrites an existing `config.json`. Re-run it after
editing the file by hand to check the connection again (this needs `jq`).

If you installed with `omarchy plugin add`, the plugin creates the file with
empty values on first start; fill them in and reopen the pulldown.

The file is created readable by you only (`0600`, in a `0700` directory),
because it holds your API token. It is not in `~/.config/omarchy/shell.json`
on purpose: that file is often shared in dotfile repositories. If you keep
`~/.config` in git, exclude `omavikunja/`.

For Vikunja Cloud, the server URL is `https://app.vikunja.cloud`.

## What it touches

**Network:** one server, the `serverUrl` in your config file, under
`<serverUrl>/api/v2/`. Use `https://`; `install.sh` warns about plain
`http://` to another machine. There is no telemetry, no update check and no
other host. "Open in the browser" hands a link on that same server to your
browser.

**Secret:** one API token, stored only in `~/.config/omavikunja/config.json`.
It is sent only to that server, as the `Authorization` header. It is never put
on a command line, in a log or in a notification, and never printed.

**Files:** OmaVikunja writes only to its own directories:

| Path | What |
|---|---|
| `~/.config/omavikunja/config.json` | server URL, token and options (`0600`) |
| `~/.local/state/omavikunja/` | the plugin's state |
| `~/.config/omarchy/plugins/cschaba.omavikunja` | the symlink `install.sh` makes to your checkout |

Your bar layout in `~/.config/omarchy/shell.json` changes only through
`omarchy plugin enable` and `omarchy bar put`, the same commands you would
type. Nothing else is written. A keybinding in `~/.config/hypr/bindings.lua` is
printed for you to add yourself.

## Uninstall

```bash
./uninstall.sh            # disable, take off the bar, remove the symlink
./uninstall.sh --purge    # also delete ~/.config/omavikunja (with the token) and ~/.local/state/omavikunja
```

A plain uninstall keeps your config, so a reinstall picks up where you left
off. `--purge` deletes the token from disk. The token itself stays valid until
you delete it in Vikunja under *Settings → API Tokens*.

The keybinding, if you added one, is yours to remove; the script tells you
where it is.

## Development

See [AGENTS.md](AGENTS.md) for conventions and [DEVELOPMENT.md](DEVELOPMENT.md)
for where everything else is documented.

## License

[MIT](LICENSE)
