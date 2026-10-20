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
- Integration workflow (`.github/workflows/integration.yml`): starts a
  throwaway Vikunja in Docker, 2.4.0 and `latest`, on pull requests and
  weekly. `tests/integration/run.sh` registers a user and an API token with
  the README's scopes, seeds projects and 56 tasks, and checks the API v2
  facts in `docs/ARCHITECTURE.md`: the envelope, pagination, the no-due-date
  sentinel, `PATCH` leaving other fields alone, Quick Add Magic stored
  literally, the error body. Scrubbed responses are uploaded as an artifact,
  for use as test fixtures.
