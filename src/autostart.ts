import { execFileSync } from 'child_process';
import { existsSync, mkdirSync, rmSync, writeFileSync } from 'fs';
import { homedir } from 'os';
import { dirname, join } from 'path';

// OS autostart registration for the daemon (vault_sync_control R17, R21),
// mirroring the Dart AutostartRegistrar so both front-ends register the same
// persistent service: a launchd LaunchAgent on macOS, a systemd user unit on
// Linux. The service runs `entropyd run --state-root <dir>` — the daemon
// serves every vault registered under its state root (~/.entropy-sync), so the
// service definition carries no per-vault config. Idempotent (re-registering
// replaces the definition) and reversible.

export const LAUNCHD_LABEL = 'com.entropy.daemon';
export const SYSTEMD_UNIT = 'entropyd';

export interface Runner {
  run(executable: string, args: string[]): void;
}

const systemRunner: Runner = {
  run: (executable, args) => {
    execFileSync(executable, args);
  },
};

export function macPlistPath(home: string = homedir()): string {
  return join(home, 'Library', 'LaunchAgents', `${LAUNCHD_LABEL}.plist`);
}

export function linuxUnitPath(home: string = homedir()): string {
  return join(home, '.config', 'systemd', 'user', `${SYSTEMD_UNIT}.service`);
}

export function launchdPlist(
  binPath: string,
  args: string[],
  logDir: string,
): string {
  const programArgs = [binPath, ...args]
    .map((a) => `    <string>${a}</string>`)
    .join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
${programArgs}
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardErrorPath</key>
  <string>${join(logDir, 'entropyd.err.log')}</string>
  <key>StandardOutPath</key>
  <string>${join(logDir, 'entropyd.out.log')}</string>
</dict>
</plist>
`;
}

export function systemdUnit(binPath: string, args: string[]): string {
  const execStart = [binPath, ...args].join(' ');
  return `[Unit]
Description=entropy-sync daemon
After=network-online.target

[Service]
ExecStart=${execStart}
Restart=on-failure

[Install]
WantedBy=default.target
`;
}

export interface AutostartOptions {
  binPath: string;
  /** The daemon state root (registry, replicas, logs) — ~/.entropy-sync. */
  stateRoot: string;
  platform?: NodeJS.Platform;
  home?: string;
  runner?: Runner;
}

/** Write and load the autostart service. Idempotent — replaces any existing one. */
export function registerAutostart(opts: AutostartOptions): void {
  const platform = opts.platform ?? process.platform;
  const home = opts.home ?? homedir();
  const runner = opts.runner ?? systemRunner;
  const args = ['run', '--state-root', opts.stateRoot];

  if (platform === 'darwin') {
    const path = macPlistPath(home);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, launchdPlist(opts.binPath, args, opts.stateRoot));
    try {
      runner.run('launchctl', ['unload', path]);
    } catch {
      // Not yet loaded — fine.
    }
    runner.run('launchctl', ['load', path]);
  } else if (platform === 'linux') {
    const path = linuxUnitPath(home);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, systemdUnit(opts.binPath, args));
    runner.run('systemctl', ['--user', 'daemon-reload']);
    runner.run('systemctl', ['--user', 'enable', '--now', SYSTEMD_UNIT]);
  } else {
    throw new Error(`autostart not supported on ${platform}`);
  }
}

/** Remove the autostart service so the daemon no longer starts on login. */
export function unregisterAutostart(
  opts: Pick<AutostartOptions, 'platform' | 'home' | 'runner'> = {},
): void {
  const platform = opts.platform ?? process.platform;
  const home = opts.home ?? homedir();
  const runner = opts.runner ?? systemRunner;

  if (platform === 'darwin') {
    const path = macPlistPath(home);
    try {
      runner.run('launchctl', ['unload', path]);
    } catch {
      // ignore
    }
    if (existsSync(path)) rmSync(path);
  } else if (platform === 'linux') {
    try {
      runner.run('systemctl', ['--user', 'disable', '--now', SYSTEMD_UNIT]);
    } catch {
      // ignore
    }
    const path = linuxUnitPath(home);
    if (existsSync(path)) rmSync(path);
  } else {
    throw new Error(`autostart not supported on ${platform}`);
  }
}
