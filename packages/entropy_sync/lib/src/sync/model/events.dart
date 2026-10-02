/// Event and feed row types of `vault_sync`: the change feed row shape shared
/// by the local replica and the server's `_changes`, the change / conflict /
/// status stream payloads (R6, R9, R17).
library;

import 'sync_doc.dart';

/// Where a change originated: minted by a local write ([local]) or grafted
/// from the server ([remote]). The shells materialize files and drive history
/// from exactly this tag (`vault_sync` R6).
enum ChangeOrigin { local, remote }

/// One row of a change feed — the same shape as the server's `_changes` with
/// `style=all_docs` (`vault_sync` RV4): every leaf revision is listed, which
/// is what makes conflicting leaves visible at all.
class ChangeRow {
  const ChangeRow({
    required this.seq,
    required this.id,
    required this.leafRevs,
    required this.winnerRev,
    required this.deleted,
  });

  /// Opaque sequence string — never parsed as a number by the client (RV4).
  final String seq;

  /// Document id.
  final String id;

  /// All leaf revisions of the document, the winner first.
  final List<String> leafRevs;

  /// The winning revision — a pure function of the tree (R9).
  final String winnerRev;

  /// Whether the winning revision is a tombstone.
  final bool deleted;

  @override
  String toString() => 'ChangeRow($seq $id $leafRevs)';
}

/// One event of the change stream: a document reached a new winning revision
/// (`vault_sync` R6). [doc] is the new winner (possibly a tombstone).
class Change {
  const Change({
    required this.id,
    required this.doc,
    required this.origin,
    required this.seq,
  });

  final String id;
  final SyncDoc doc;
  final ChangeOrigin origin;

  /// The local sequence this change advanced the replica to (as a string).
  final String seq;

  @override
  String toString() => 'Change($id @ ${doc.rev}, ${origin.name})';
}

/// One event of the conflict stream: a document holds more than one live leaf
/// (`vault_sync` R9). Each loser carries its full content — body and
/// attachment reference — so the shell can rescue it before resolving.
class ConflictReport {
  const ConflictReport({
    required this.id,
    required this.winnerRev,
    required this.losers,
  });

  final String id;

  /// The deterministic winner (live > deleted, then generation, then
  /// lexicographically greater hash — identical on every replica, R9).
  final String winnerRev;

  /// Every live non-winning leaf, with rev, body, attachment, and tombstone
  /// flag populated.
  final List<SyncDoc> losers;

  @override
  String toString() =>
      'ConflictReport($id winner $winnerRev, losers ${losers.length})';
}

/// One value of the status stream — live health for the control surfaces
/// (`vault_sync` R17): hub reachability, local revisions awaiting push, the
/// current pull checkpoint, and the latest error if any.
class SyncStatus {
  const SyncStatus({
    required this.online,
    required this.pendingPush,
    required this.lastSeq,
    this.error,
  });

  final bool online;
  final int pendingPush;

  /// The current pull checkpoint (opaque server sequence string).
  final String lastSeq;

  /// The latest error (`unreachable hub`, `auth failure`, …), `null` when
  /// healthy.
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is SyncStatus &&
      other.online == online &&
      other.pendingPush == pendingPush &&
      other.lastSeq == lastSeq &&
      other.error == error;

  @override
  int get hashCode => Object.hash(online, pendingPush, lastSeq, error);

  @override
  String toString() => 'SyncStatus(online: $online, pendingPush: $pendingPush, '
      'lastSeq: $lastSeq${error == null ? '' : ', error: $error'})';
}
