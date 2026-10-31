# Security

## Reporting a vulnerability

Please don't open a public issue. Report it privately through
[GitHub's private vulnerability reporting](https://github.com/bonout/plume/security/advisories/new);
you'll get an answer there, and the fix and advisory are published together.

## What Plume stores and sends

- **Network**: only to the Nextcloud server you sign in to, over HTTPS
  (plain HTTP is accepted only for servers on the local network). Standard
  WebDAV and OCS; no analytics, no third-party service.
- **Credentials**: Login Flow v2 gives Plume its own app password, never your
  account password. It is kept in the Keychain, shared only with Plume's
  extensions, and revoked on the server when you sign out.
- **On the device**: the file list (SQLite), thumbnails, recently opened files
  and files kept offline, in the app group container shared by the app and
  its extensions. Signing out removes the file list and the downloaded
  files.
- **Spotlight**: file and folder names and thumbnails are indexed on the
  device; signing out removes them.

## The repository

- `main` only changes through pull requests that pass CI; release tags are
  protected.
- GitHub Actions are pinned by commit SHA, and workflows get read-only tokens
  unless a job needs more.
- Signing material (Apple team, App Store Connect key, certificate) lives in
  the `release` environment's secrets, never in the code. Secret scanning and
  push protection are on.
