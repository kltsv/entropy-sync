# Entropy Sync

End-to-end encrypted folder synchronization through your CouchDB server.
A pure Dart replication/crypto library, the `entropyd` desktop daemon, and
an Obsidian control/installer plugin over that daemon.

## Install in Obsidian with BRAT

In BRAT, choose **Add a beta plugin** and enter `kltsv/entropy-sync`.
Enable **Entropy Sync**. Paste your server setup URI and vault E2EE passphrase
in plugin settings, configure the vault, then choose **Install & start**.
The plugin downloads the matching daemon for your OS/CPU, verifies its embedded
SHA-256 and installs it outside the vault (`~/.entropy-sync/bin/`). No manual
URL/checksum or Dart installation is needed. The daemon persists beyond Obsidian.
Supported hosts: macOS and Linux x64/arm64, Windows x64.

A running Entropy daemon is shared with other front ends. The plugin controls
it over authenticated loopback HTTP and performs no replication itself.
Configure one database per independent vault. Keep the E2EE passphrase private.

## CLI, server and library

Release assets `entropyd-<os>-<arch>` are standalone native binaries.
Run `entropyd --help` for registration, run/status, history and server commands.
`entropyd hub` provisions CouchDB/Caddy over SSH and creates databases/grants;
`tools/vps-provision/` also provides a shell provisioning entry point.
`packages/entropy_sync` has no dependency on history; `packages/entropy_daemon`
composes it with the pinned [Entropy History](https://github.com/kltsv/entropy-hist)
engine. The library and history format are shared, not reimplemented in JS.

## Develop

```sh
npm ci
node tool/checkout-history.mjs
cd packages/entropy_sync
dart pub get && dart analyze && dart test
cd ../entropy_daemon
dart pub get && dart analyze && dart test
cd ../..
python3 compile.py
npm test
npm run native
npm run build
```

`history-dependency.json` and the daemon's Git dependency pin the same History
commit. The checkout command gets its specs and Dart-generated interop fixtures
in ignored `.deps/`; it never replaces dirty work. Local development can point
`spec_sources_overrides.json` and `pubspec_overrides.yaml` at a sibling checkout.
The daemon tests use local CouchDB emulation; live server tests are opt-in.

## Release

Keep the manifest, package and daemon versions equal; push an equal version tag
(e.g. `0.2.0`). CI builds each native host and assembles three BRAT files with
all daemon checksums embedded. Native assets and `SHA256SUMS` belong to the same
immutable release. Publish a new tag for every binary change.

MIT licensed. Dependency licenses remain their respective owners'.
