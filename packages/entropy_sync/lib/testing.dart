/// Test doubles shared across the entropy-sync stack: the in-memory CouchDB
/// emulator serving real HTTP, so the real transport is exercised end-to-end
/// without a live server (`vault_sync` test-spec "server").
library;

export 'src/testing/couch_emulator.dart';
