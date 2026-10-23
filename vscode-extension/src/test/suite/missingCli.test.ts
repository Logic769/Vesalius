import * as assert from 'assert';
import * as vscode from 'vscode';
import type { VesaliusApi } from '../../extension';
import { activateExtension, fileUri, vesaliusDiagnostics, waitFor } from './helpers';

// Runs with no `vesalius` anywhere the extension looks (PATH is reduced to system folders and
// VESALIUS_CLI_PATH is empty). The real CLI path arrives in VESALIUS_TEST_CLI and is applied the
// way a user would: through the vesalius.cliPath setting.

suite('Vesalius: no CLI installed', () => {
  let api: VesaliusApi;

  suiteSetup(async () => {
    api = await activateExtension();
  });

  suiteTeardown(async () => {
    await vscode.workspace.getConfiguration('vesalius').update('cliPath', undefined, vscode.ConfigurationTarget.Global);
  });

  test('starts in the "not installed" state', () => {
    assert.strictEqual(api.cli, undefined);
    assert.strictEqual(api.statusBar.item.text, '$(circle-slash) Vesalius');
    assert.strictEqual(api.statusBar.item.command, 'vesalius.installCli');
    assert.deepStrictEqual(api.health.getChildren(), [], 'the view shows its install welcome instead of a tree');
    assert.deepStrictEqual(vesaliusDiagnostics(fileUri('src/cycle/a.ts')), []);
  });

  test('a vesalius.cliPath that does not exist keeps it missing', async () => {
    await vscode.workspace.getConfiguration('vesalius').update('cliPath', '/nonexistent/vesalius', vscode.ConfigurationTarget.Global);
    await new Promise((resolve) => setTimeout(resolve, 500));
    assert.strictEqual(api.cli, undefined);
    assert.strictEqual(api.statusBar.item.text, '$(circle-slash) Vesalius');
  });

  test('pointing vesalius.cliPath at the CLI recovers: index, health and Problems appear', async () => {
    const cli = process.env.VESALIUS_TEST_CLI;
    assert.ok(cli, 'VESALIUS_TEST_CLI is set by the runner');
    await vscode.workspace.getConfiguration('vesalius').update('cliPath', cli, vscode.ConfigurationTarget.Global);
    const location = await waitFor('the CLI to resolve from the setting', () => api.cli);
    assert.strictEqual(location.command, cli);
    assert.strictEqual(location.source, 'vesalius.cliPath setting');
    await api.ready;
    await waitFor('the health score in the status bar', () => /^\$\(pulse\) Health \d+$/.test(api.statusBar.item.text));
    await waitFor('the cycle finding in Problems', () => vesaliusDiagnostics(fileUri('src/cycle/a.ts')).some((d) => d.code === 'dependency-cycle'));
  });
});
