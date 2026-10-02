import { existsSync, mkdirSync } from 'fs';
import { join } from 'path';

import { App, FileSystemAdapter, Modal, Notice, Plugin } from 'obsidian';

import { registerAutostart } from './autostart';
import { planBootstrap } from './bootstrapPlanner';
import { ControlClient, ControlVaultConflict } from './controlClient';
import {
  daemonRelease,
  releaseAsset,
  downloadAndVerify,
  installedVersion,
} from './daemonInstaller';
import { discoverDaemon } from './discovery';
import {
  daemonConfigDir,
  FileSecretStore,
  SECRET_PASSPHRASE,
  SECRET_SERVER_PASSWORD,
} from './secretStore';
import { decodeSetupUri } from './setupUri';
import { SyncTargetRegistry } from './targetRegistry';
import {
  DEFAULT_SETTINGS,
  EntropySyncSettings,
  EntropySyncSettingTab,
} from './settings';
import type { DaemonStatus } from './types';

/**
 * This vault's database already belongs to a different vault. Not fatal: both
 * folders would become one vault and converge to the same content set, which
 * the owner may well intend — so the surface states the consequence and
 * re-calls with `allowSharedDatabase` on confirmation (vault_sync_control).
 */
export class SharedDatabaseWarning extends Error {
  constructor(
    readonly conflictsWith: string,
    readonly endpoint: string,
    readonly database: string,
  ) {
    super(
      `This server database (${endpoint} / ${database}) is already used by ` +
        `vault "${conflictsWith}". Both folders would become one vault and ` +
        `converge to the same content set, and must share the same passphrase.`,
    );
    this.name = 'SharedDatabaseWarning';
  }
}

/**
 * This vault's folder is another configured vault's folder, or nested either
 * way. Unlike a shared database this has no override — two shells over one
 * directory read each other's writes as local edits and mint revisions forever.
 */
export class FolderOverlapError extends Error {
  constructor(
    readonly conflictsWith: string,
    readonly otherRoot: string,
  ) {
    super(
      `This folder overlaps vault "${conflictsWith}" (${otherRoot}). Two ` +
        `vaults must not share or nest folders — choose another folder.`,
    );
    this.name = 'FolderOverlapError';
  }
}

/// The Obsidian control/installer plane (vault_sync_control R22). It installs and
/// drives the external entropyd daemon for the currently open vault and
/// shows its status — the same surface as the entropy app — and runs NO
/// replication of its own (N3). Interchangeable with the app over one daemon (R20).
export default class EntropySyncPlugin extends Plugin {
  settings: EntropySyncSettings = DEFAULT_SETTINGS;
  readonly secrets = new FileSecretStore();

  async onload(): Promise<void> {
    await this.loadSettings();
    this.addSettingTab(new EntropySyncSettingTab(this.app, this));
    this.addRibbonIcon('refresh-cw', 'Entropy Sync status', () =>
      this.showStatus(),
    );
    this.addCommand({
      id: 'sync-now',
      name: 'Sync now',
      callback: () => this.syncNow(),
    });
    this.addCommand({
      id: 'show-status',
      name: 'Show sync status',
      callback: () => this.showStatus(),
    });
  }

  async loadSettings(): Promise<void> {
    this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData());
  }

  async saveSettings(): Promise<void> {
    await this.saveData(this.settings);
  }

  private vaultId(): string {
    return this.app.vault.getName();
  }

  private binPath(): string {
    const dir = join(daemonConfigDir(), 'bin');
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    return join(dir, process.platform === 'win32' ? 'entropyd.exe' : 'entropyd');
  }

  /** A client to a running daemon, or null if none is discoverable (R18/R20). */
  private client(): ControlClient | null {
    const endpoint = discoverDaemon();
    return endpoint ? new ControlClient(endpoint.port, endpoint.token) : null;
  }

  /**
   * Per-vault setup from a setup-URI + transfer secret + passphrase (R23, D9).
   *
   * A database another vault already uses raises [SharedDatabaseWarning]: the
   * caller states the consequence and re-calls with `allowSharedDatabase` when
   * the owner confirms. An overlapping folder raises [FolderOverlapError],
   * which has no override.
   */
  async configureVault(
    setupUri: string,
    transferSecret: string,
    passphrase: string,
    options: { allowSharedDatabase?: boolean } = {},
  ): Promise<void> {
    // Throws (rejected) before storing anything if the URI/secret is wrong.
    const connection = decodeSetupUri(setupUri, transferSecret);  // secret may be inside the string
    const id = this.vaultId();

    // The absolute vault folder the daemon will own. Desktop-only: a
    // non-filesystem adapter (mobile) has no folder a daemon could serve —
    // rejected before storing anything.
    const adapter = this.app.vault.adapter;
    if (!(adapter instanceof FileSystemAdapter)) {
      throw new Error(
        'This vault has no local folder (non-desktop adapter) — ' +
          'entropy-sync needs the desktop filesystem vault.',
      );
    }
    const vaultRoot = adapter.getBasePath();

    // Check both isolation rules before storing anything (nothing partial on
    // rejection). Database first — it is the one the owner can act on.
    const registry = new SyncTargetRegistry();
    if (!options.allowSharedDatabase) {
      const other = registry.conflict(id, connection.endpoint, connection.database);
      if (other) {
        throw new SharedDatabaseWarning(other, connection.endpoint, connection.database);
      }
    }
    // The folder rule holds regardless of the acknowledgement: consenting to
    // share a database never makes two shells over one directory safe.
    const overlapping = registry.folderConflict(id, vaultRoot);
    if (overlapping) {
      throw new FolderOverlapError(overlapping.vaultId, overlapping.vaultRoot);
    }

    // Secrets go to the local store keyed by vault — never into the vault, never synced.
    this.secrets.write(id, SECRET_SERVER_PASSWORD, connection.serverPassword);
    this.secrets.write(id, SECRET_PASSPHRASE, passphrase);
    registry.claim(id, connection.endpoint, connection.database, vaultRoot);
    this.settings.endpoint = connection.endpoint;
    this.settings.database = connection.database;
    this.settings.serverUser = connection.serverUser;
    this.settings.vaultRoot = vaultRoot;
    await this.saveSettings();

    // Setup ends with a syncing vault, not a stored form (R21, R23): hand the
    // profile to a running daemon now; with no daemon yet it stays pending and
    // installAndStart() hands it over right after the daemon starts.
    const client = this.client();
    if (client) {
      await this.handOffVault(client, options.allowSharedDatabase === true);
    } else {
      new Notice(
        `Vault "${id}" configured for ${connection.endpoint}. ` +
          'Press "Install & start" to begin syncing.',
      );
    }
  }

  /**
   * Hand the configured vault's profile to the daemon over the control channel
   * (the add-vault command): the daemon registers the vault and starts serving
   * it with no restart. Idempotent — re-sending the same vault attaches (R20).
   * Only the non-secret profile plus the two secrets travel, loopback-only;
   * nothing is logged.
   */
  private async handOffVault(
    client: ControlClient,
    allowSharedDatabase = false,
  ): Promise<boolean> {
    const id = this.vaultId();
    const { endpoint, database, serverUser, vaultRoot } = this.settings;
    if (!endpoint || !database || !serverUser || !vaultRoot) return false;
    const passphrase = this.secrets.read(id, SECRET_PASSPHRASE);
    const serverPassword = this.secrets.read(id, SECRET_SERVER_PASSWORD);
    if (passphrase == null || serverPassword == null) {
      new Notice(`No stored secrets for vault "${id}" — re-run setup.`);
      return false;
    }
    try {
      await client.addVault({
        profile: { vaultId: id, vaultRoot, endpoint, database, serverUser },
        passphrase,
        serverPassword,
        ...(allowSharedDatabase ? { allowSharedDatabase: true } : {}),
      });
      new Notice(`Vault "${id}" is syncing (entropyd).`);
      return true;
    } catch (e) {
      // The vault is not being served, so its claim must not stay behind
      // making that database look occupied.
      new SyncTargetRegistry().release(id);
      if (e instanceof ControlVaultConflict) {
        new Notice(
          e.isAcknowledgeable
            ? `Daemon refused vault "${id}": its database is already used by ` +
              `"${e.conflictsWith}". Configure again to confirm sharing it.`
            : `Daemon refused vault "${id}": its folder overlaps vault ` +
              `"${e.conflictsWith}". Two vaults must not share or nest folders.`,
        );
      } else {
        new Notice(`Vault handoff failed: ${String(e)}`);
      }
      return false;
    }
  }

  /** Poll discovery until a daemon advertises its control channel, or time out. */
  private async waitForDaemon(timeoutMillis: number): Promise<ControlClient | null> {
    const deadline = Date.now() + timeoutMillis;
    for (;;) {
      const client = this.client();
      if (client) return client;
      if (Date.now() >= deadline) return null;
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }

  /** Idempotent install/attach/upgrade + start (R21). */
  async installAndStart(): Promise<void> {
    const required = daemonRelease.daemonVersion;
    const bin = this.binPath();
    const decision = planBootstrap({
      running: this.client() != null,
      installedVersion: installedVersion(bin),
      requiredVersion: required,
      frontEnd: 'obsidian',
    });

    if (decision.action === 'attach') {
      new Notice('Daemon already running — attached.');
      // Hand over a profile configured while no handoff had happened yet —
      // idempotent for an already-registered vault (R20).
      const running = this.client();
      if (running) await this.handOffVault(running);
      return;
    }
    if (decision.action === 'install' || decision.action === 'upgrade') {
      try {
        await downloadAndVerify(
          releaseAsset(),
          bin,
        );
        new Notice(`Daemon ${decision.action}ed and verified.`);
      } catch (e) {
        new Notice(`Install failed: ${String(e)}`);
        return;
      }
    }
    this.startDaemon(bin);
    new Notice('Daemon started.');

    // Setup ends with a syncing vault (R21, R23): once the fresh daemon
    // advertises its control channel, hand over the pending profile.
    const started = await this.waitForDaemon(10_000);
    if (started) {
      await this.handOffVault(started);
    } else {
      new Notice(
        'Daemon has not advertised its control channel yet — ' +
          'the vault is handed over on the next attach.',
      );
    }
  }

  /**
   * Register the daemon for OS autostart so it starts on login and outlives
   * Obsidian (R17, R21). On macOS/Linux this writes and loads a launchd/systemd
   * service running `entropyd run --state-root <dir>` (which also starts
   * it now via RunAtLoad); the daemon serves every vault registered under that
   * state root, so the service carries no per-vault config.
   */
  private startDaemon(bin: string): void {
    registerAutostart({
      binPath: bin,
      stateRoot: daemonConfigDir(),
    });
  }

  async syncNow(): Promise<void> {
    const client = this.client();
    if (!client) {
      new Notice('Daemon not running. Open settings to install & start.');
      return;
    }
    await client.command('syncNow', this.vaultId());
    new Notice('Sync requested.');
  }

  async showStatus(): Promise<void> {
    const client = this.client();
    if (!client) {
      new Notice('Daemon not running. Open settings to install & start.');
      return;
    }
    try {
      new StatusModal(this.app, await client.status()).open();
    } catch (e) {
      new Notice(`Cannot read daemon status: ${String(e)}`);
    }
  }
}

/// A read-only status view (vault_sync_control R17): per-vault state, last-sync,
/// un-synced count, errors and conflicts (surfaced, never merged — R9).
class StatusModal extends Modal {
  constructor(
    app: App,
    private readonly status: DaemonStatus,
  ) {
    super(app);
  }

  onOpen(): void {
    const { contentEl } = this;
    contentEl.createEl('h3', { text: `entropyd ${this.status.version}` });
    if (this.status.vaults.length === 0) {
      contentEl.createEl('p', { text: 'No vaults configured.' });
      return;
    }
    for (const vault of this.status.vaults) {
      contentEl.createEl('h4', { text: `${vault.vaultId} — ${vault.state}` });
      const last =
        vault.lastSyncMillis != null
          ? new Date(vault.lastSyncMillis).toLocaleString()
          : '—';
      contentEl.createEl('p', { text: `Last sync: ${last}` });
      contentEl.createEl('p', { text: `Un-synced changes: ${vault.unsynced}` });
      if (vault.error) {
        contentEl.createEl('p', { text: `Error: ${vault.error}` });
      }
      if (vault.conflicts.length > 0) {
        contentEl.createEl('p', {
          text: 'Conflicts (restore previous version from history):',
        });
        const list = contentEl.createEl('ul');
        for (const path of vault.conflicts) {
          list.createEl('li', { text: path });
        }
      }
    }
  }

  onClose(): void {
    this.contentEl.empty();
  }
}
