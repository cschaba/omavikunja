# Changelog

Notable changes per release. Dates are ISO. This project follows
[semantic versioning](https://semver.org).

## [Unreleased]

- Project scaffold: manifest, a bar widget that loads and opens an empty
  pulldown, install and uninstall scripts, smoke test, CI and release
  workflows — ported from omaipsum.
- Design decisions recorded in `docs/ARCHITECTURE.md`: configuration and the
  API token live in `~/.config/omavikunja/config.json`; Vikunja API v2 only
  (server 2.4.0 or newer); HTTP through a dependency-free JavaScript library.
  The widget settings in `shell.json` are gone.
- `install.sh` sets up the connection. If
  `~/.config/omavikunja/config.json` does not exist, it asks for the server URL
  and the API token (the token is read without echo), validates both, and
  writes the file `0600` in a `0700` directory. It never overwrites an
  existing config. Run without a terminal, or given blank answers, it writes
  empty values and says where to fill them in. If `curl` is present, it checks
  the connection with `GET /api/v2/user`, passing the token on stdin rather
  than on the command line. It warns about plain `http://` to a host other than
  this machine.
- `uninstall.sh --help` and `--purge` say that purging deletes the API token,
  and that the token stays valid in Vikunja until you delete it there.
- README: a *What it touches* section covering the one server, the one file
  holding the token, and the files written.
- `tests/installer.sh` runs both scripts against a throwaway HOME with
  `omarchy` stubbed out, a pty for the prompts and a local stand-in server.
