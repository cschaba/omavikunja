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
- `Vikunja.js`, the API v2 client: server info and version check, current
  user, open tasks (all pages, soonest due first), project titles. Pure request
  builders and response parsers apart from the one function that does HTTP;
  one error shape for the UI; the token never reaches a message.
  `tests/lib/load-vikunja.js` loads it under node.
