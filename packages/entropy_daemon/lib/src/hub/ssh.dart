import 'dart:convert';
import 'dart:io';

/// The result of one command run on a hub.
class HubCommandResult {
  const HubCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;
}

/// Raised when the hub cannot be reached at all — the SSH client could not
/// authenticate or connect. Distinct from a command that ran and failed
/// (`vault_sync_hub` C1): nothing was attempted on the host.
class HubUnreachable implements Exception {
  HubUnreachable({required this.sshTarget, required this.detail});

  final String sshTarget;
  final String detail;

  @override
  String toString() =>
      'HubUnreachable: cannot reach "$sshTarget" over SSH — $detail. The key '
      'is supplied by your SSH agent or ~/.ssh/config; entropy never stores '
      'one. Check that `ssh $sshTarget true` works.';
}

/// Runs commands on a hub. The production implementation shells out to the
/// **system SSH client**, so authentication is whatever the agent and the
/// user's SSH config already resolve — this module never holds a key
/// (`vault_sync_hub` C1). Tests supply their own.
abstract class HubRunner {
  /// Run [command] on [sshTarget]. [stdin] is piped in when given.
  Future<HubCommandResult> run(
    String sshTarget,
    String command, {
    String? stdin,
  });

  /// Copy [content] to [remotePath] on the host, creating parent directories.
  Future<void> writeFile(String sshTarget, String remotePath, String content);

  /// Whether the host answers at all. Never throws.
  Future<bool> reachable(String sshTarget);
}

/// [HubRunner] over the system `ssh` binary.
///
/// Batch mode is deliberate: a hub whose key is not already available must
/// fail fast with [HubUnreachable] rather than block a GUI on a hidden
/// passphrase prompt.
class SystemSshRunner implements HubRunner {
  const SystemSshRunner({this.connectTimeoutSeconds = 15});

  final int connectTimeoutSeconds;

  List<String> _baseArgs(String sshTarget) => [
        '-o',
        'BatchMode=yes',
        '-o',
        'ConnectTimeout=$connectTimeoutSeconds',
        sshTarget,
      ];

  @override
  Future<bool> reachable(String sshTarget) async {
    try {
      final r = await Process.run('ssh', [..._baseArgs(sshTarget), 'true']);
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<HubCommandResult> run(
    String sshTarget,
    String command, {
    String? stdin,
  }) async {
    final Process proc;
    try {
      proc = await Process.start('ssh', [..._baseArgs(sshTarget), command]);
    } on ProcessException catch (e) {
      throw HubUnreachable(sshTarget: sshTarget, detail: e.message);
    }
    if (stdin != null) {
      proc.stdin.write(stdin);
    }
    await proc.stdin.close();
    final out = await proc.stdout.transform(utf8.decoder).join();
    final err = await proc.stderr.transform(utf8.decoder).join();
    final code = await proc.exitCode;
    // 255 is ssh's own transport failure — the command never ran.
    if (code == 255) {
      throw HubUnreachable(
        sshTarget: sshTarget,
        detail: err.trim().isEmpty ? 'ssh exited 255' : err.trim(),
      );
    }
    return HubCommandResult(exitCode: code, stdout: out, stderr: err);
  }

  @override
  Future<void> writeFile(
    String sshTarget,
    String remotePath,
    String content,
  ) async {
    // Written through a heredoc-free stdin pipe so the content needs no
    // shell quoting of its own.
    final dir = remotePath.substring(0, remotePath.lastIndexOf('/'));
    final result = await run(
      sshTarget,
      "sudo mkdir -p '$dir' && sudo tee '$remotePath' >/dev/null",
      stdin: content,
    );
    if (!result.ok) {
      throw HubOperationFailed(
        operation: 'write $remotePath',
        detail: result.stderr.trim(),
      );
    }
  }
}

/// Raised when a command ran on the hub and failed. Carries the host's own
/// message, which is the actionable part.
class HubOperationFailed implements Exception {
  HubOperationFailed({required this.operation, required this.detail});

  final String operation;
  final String detail;

  @override
  String toString() => 'HubOperationFailed: $operation — $detail';
}
