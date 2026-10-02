import { App, Notice, PluginSettingTab, Setting } from 'obsidian';

import type EntropySyncPlugin from './main';
import { SharedDatabaseWarning } from './main';

export interface EntropySyncSettings {
  endpoint: string;
  database: string;
  serverUser: string;
  /** Absolute path of the configured vault's folder — the root the daemon owns. */
  vaultRoot: string;
}

export const DEFAULT_SETTINGS: EntropySyncSettings = {
  endpoint: '',
  database: 'vault',
  serverUser: '',
  vaultRoot: '',
};

/// The plugin's settings surface (vault_sync_control R17, R22, R23): per-vault
/// setup from a paste, and one-button daemon install/start — for the vault
/// Obsidian currently has open. Runs no sync of its own.
export class EntropySyncSettingTab extends PluginSettingTab {
  private uri = '';
  private transferSecret = '';
  private passphrase = '';

  /// Set once the owner has been warned that this database already belongs to
  /// another vault; the next click carries the acknowledgement through.
  private sharedDbConfirmed = false;

  constructor(
    app: App,
    private readonly plugin: EntropySyncPlugin,
  ) {
    super(app, plugin);
  }

  display(): void {
    const { containerEl } = this;
    containerEl.empty();
    containerEl.createEl('h2', { text: 'Entropy Sync' });
    containerEl.createEl('p', {
      text:
        'Install and control the entropyd daemon for this vault. The plugin ' +
        'runs no sync itself — the daemon does.',
    });

    // The transfer secret rides inside the pasted string by default; the field
    // below is only for the split form (vault_sync_control D9).
    new Setting(containerEl)
      .setName('Setup-URI')
      .addText((t) =>
        t.setPlaceholder('entropy-sync://setup#…').onChange((v) => (this.uri = v)),
      );

    new Setting(containerEl)
      .setName('Transfer secret')
      .setDesc('Only if the string does not carry it.')
      .addText((t) => {
        t.inputEl.type = 'password';
        t.onChange((v) => (this.transferSecret = v));
      });

    new Setting(containerEl)
      .setName('E2EE passphrase')
      .addText((t) => {
        t.inputEl.type = 'password';
        t.onChange((v) => (this.passphrase = v));
      });

    new Setting(containerEl).addButton((b) =>
      b
        .setButtonText('Configure vault')
        .setCta()
        .onClick(async () => {
          try {
            await this.plugin.configureVault(
              this.uri,
              this.transferSecret,
              this.passphrase,
              { allowSharedDatabase: this.sharedDbConfirmed },
            );
            this.sharedDbConfirmed = false;
            this.display();
          } catch (e) {
            // A shared database is the owner's to choose: state the
            // consequence once, then let the next click through. A folder
            // overlap gets no such second chance.
            if (e instanceof SharedDatabaseWarning) {
              this.sharedDbConfirmed = true;
              new Notice(`${e.message} Press "Configure vault" again to confirm.`);
            } else {
              new Notice(`Setup failed: ${String(e)}`);
            }
          }
        }),
    );

    new Setting(containerEl)
      .setName('Daemon')
      .setDesc(
        this.plugin.settings.endpoint
          ? `Configured for ${this.plugin.settings.endpoint}`
          : 'Not configured yet — paste a setup-URI above.',
      )
      .addButton((b) =>
        b
          .setButtonText('Install & start')
          .setCta()
          .onClick(() => this.plugin.installAndStart()),
      )
      .addButton((b) =>
        b.setButtonText('Sync now').onClick(() => this.plugin.syncNow()),
      );
  }
}
