import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One hub the owner administers: **label, SSH target, domain and ACME
/// email — and nothing secret** (`vault_sync_hub` C1).
///
/// Authentication is delegated to the system SSH client, so the key stays
/// wherever the owner already keeps it. A stolen device whose agent holds no
/// key therefore yields no access to the hub at all.
class HubRecord {
  const HubRecord({
    required this.label,
    required this.sshTarget,
    required this.domain,
    required this.acmeEmail,
  });

  /// The owner's name for this hub, and its identity in the registry.
  final String label;

  /// `user@host` for the system SSH client.
  final String sshTarget;

  /// The hostname whose DNS points at the host; where clients connect.
  final String domain;

  /// Address for the certificate authority's notifications.
  final String acmeEmail;

  /// Where clients reach this hub.
  String get endpoint => 'https://$domain';

  Map<String, Object?> toJson() => {
        'label': label,
        'sshTarget': sshTarget,
        'domain': domain,
        'acmeEmail': acmeEmail,
      };

  static HubRecord fromJson(Map<String, Object?> json) => HubRecord(
        label: json['label'] as String,
        sshTarget: json['sshTarget'] as String,
        domain: json['domain'] as String,
        acmeEmail: json['acmeEmail'] as String? ?? '',
      );
}

/// The persisted, **non-secret** list of hubs, one small JSON file under the
/// state root — beside the vault registry, and readable for the same reason:
/// there is nothing in it worth protecting (`vault_sync_hub` C1).
class HubRegistry {
  HubRegistry(this.stateRoot);

  final String stateRoot;

  File get _file => File(p.join(stateRoot, 'hubs.json'));

  Map<String, Object?> _load() {
    if (!_file.existsSync()) return {};
    try {
      return (jsonDecode(_file.readAsStringSync()) as Map)
          .cast<String, Object?>();
    } catch (_) {
      return {}; // a corrupt record behaves like "nothing saved"
    }
  }

  List<HubRecord> all() => [
        for (final v in _load().values)
          HubRecord.fromJson((v as Map).cast<String, Object?>()),
      ];

  HubRecord? find(String label) {
    final raw = _load()[label];
    return raw == null
        ? null
        : HubRecord.fromJson((raw as Map).cast<String, Object?>());
  }

  /// Add or update by label — adding the same label twice edits that hub
  /// rather than creating a second one.
  void upsert(HubRecord hub) {
    final map = _load()..[hub.label] = hub.toJson();
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(jsonEncode(map));
  }

  void remove(String label) {
    final map = _load();
    if (map.remove(label) != null) _file.writeAsStringSync(jsonEncode(map));
  }
}
