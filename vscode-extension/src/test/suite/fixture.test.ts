import * as assert from 'assert';
import * as vscode from 'vscode';
import type { VesaliusApi } from '../../extension';
import type { AskResult, FileContext, HealthResult, ImpactReport, IndexSummary } from '../../types';
import { activateExtension, extensionID, fileUri, mcpHandshake, screenshot, vesaliusDiagnostics, waitFor, workspaceFolder } from './helpers';

// Runs inside a real VS Code against the generated fixture repository (see ../fixture.ts) with the
// real `vesalius` CLI. Nothing is stubbed.

suite('Vesalius: fixture repository', () => {
  let api: VesaliusApi;

  suiteSetup(async () => {
    api = await activateExtension();
  });

  suiteTeardown(async () => {
    await vscode.workspace.getConfiguration('vesalius').update('diagnostics.minimumSeverity', undefined, vscode.ConfigurationTarget.Global);
  });

  test('activates and uses the CLI from VESALIUS_CLI_PATH', () => {
    assert.strictEqual(vscode.extensions.getExtension(extensionID)?.isActive, true);
    assert.ok(api.cli, 'a CLI was resolved');
    assert.strictEqual(api.cli.command, process.env.VESALIUS_CLI_PATH);
    assert.strictEqual(api.cli.source, 'VESALIUS_CLI_PATH');
  });

  test('Vesalius: Update Index indexes every file into VESALIUS_HOME', async () => {
    const summary = await vscode.commands.executeCommand<IndexSummary>('vesalius.updateIndex');
    assert.ok(summary, 'the command returned an index summary');
    assert.strictEqual(summary.filesScanned, 12);
    assert.strictEqual(summary.filesFailed, 0);
    assert.ok(summary.symbols > 100, `symbols: ${summary.symbols}`);
    assert.ok(summary.indexPath.startsWith(process.env.VESALIUS_HOME ?? '\0'), `index at ${summary.indexPath}`);
  });

  test('Problems panel shows the dependency cycle and the large file', async () => {
    const cycle = await waitFor('a Vesalius cycle diagnostic on src/cycle/a.ts', () =>
      vesaliusDiagnostics(fileUri('src/cycle/a.ts')).find((d) => /cycle/i.test(d.message)),
    );
    assert.strictEqual(cycle.message, 'Dependency cycle across 2 files');
    assert.strictEqual(cycle.severity, vscode.DiagnosticSeverity.Information, 'medium maps to Information');
    assert.strictEqual(cycle.code, 'dependency-cycle');
    assert.strictEqual(cycle.range.start.line, 0, 'no line in the finding: line 0');
    const related = cycle.relatedInformation ?? [];
    assert.ok(related.some((info) => info.message.startsWith('Suggestion: ')), 'the recommendation is attached');
    assert.ok(related.some((info) => info.location.uri.toString() === fileUri('src/cycle/b.ts').toString()), 'links the other file in the cycle');
    assert.ok(vesaliusDiagnostics(fileUri('src/cycle/b.ts')).some((d) => d.code === 'dependency-cycle'), 'b.ts has the finding too');

    const large = vesaliusDiagnostics(fileUri('src/legacy/bigReport.ts')).find((d) => d.code === 'large-file');
    assert.ok(large, 'large-file finding on bigReport.ts');
    assert.strictEqual(large.message, 'Large file: bigReport.ts');

    assert.deepStrictEqual(vesaliusDiagnostics(fileUri('src/ui/UserCard.tsx')), [], 'low findings stay hidden at the default minimum (medium)');

    await vscode.window.showTextDocument(fileUri('src/cycle/a.ts'));
    await vscode.commands.executeCommand('workbench.actions.view.problems');
    await screenshot('problems');
    await vscode.commands.executeCommand('workbench.action.closePanel');
  });

  test('vesalius.diagnostics.minimumSeverity "low" adds hints at symbol lines', async () => {
    await vscode.workspace.getConfiguration('vesalius').update('diagnostics.minimumSeverity', 'low', vscode.ConfigurationTarget.Global);
    const unused = await waitFor('an unused-symbol hint in invoice.ts', () =>
      vesaliusDiagnostics(fileUri('src/billing/invoice.ts')).find((d) => d.code === 'unused-symbols'),
    );
    assert.strictEqual(unused.severity, vscode.DiagnosticSeverity.Hint, 'low maps to Hint');
    assert.strictEqual(unused.range.start.line, 8, 'placed on InvoiceCalculator.total (line 9)');
    assert.ok(vesaliusDiagnostics(fileUri('src/ui/UserCard.tsx')).some((d) => d.code === 'unused-file'));

    await vscode.workspace.getConfiguration('vesalius').update('diagnostics.minimumSeverity', undefined, vscode.ConfigurationTarget.Global);
    await waitFor('low findings to disappear again', () => vesaliusDiagnostics(fileUri('src/ui/UserCard.tsx')).length === 0);
  });

  test('vesalius.api.ask ranks the invoice module first', async () => {
    const result = await vscode.commands.executeCommand<AskResult>('vesalius.api.ask', 'where are invoice totals calculated?');
    assert.strictEqual(result.files[0]?.path, 'src/billing/invoice.ts', `got ${result.files.map((f) => f.path).join(', ')}`);
  });

  test('Ask the Codebase: accepting the top answer opens the file', async () => {
    await vscode.commands.executeCommand('workbench.action.closeAllEditors');
    const answered = new Promise<AskResult>((resolve) => {
      const subscription = api.onDidAnswer((result) => {
        subscription.dispose();
        resolve(result);
      });
    });
    const command = vscode.commands.executeCommand<AskResult>('vesalius.ask', 'where are invoice totals calculated?');
    const result = await answered;
    assert.strictEqual(result.files[0].path, 'src/billing/invoice.ts');
    await screenshot('ask');
    await vscode.commands.executeCommand('workbench.action.acceptSelectedQuickOpenItem');
    await command;
    const expectedLine = Number.parseInt(result.files[0].lines ?? result.files[0].symbols[0].lines, 10) - 1;
    const editor = await waitFor('invoice.ts to open', () => (vscode.window.activeTextEditor?.document.uri.path.endsWith('src/billing/invoice.ts') ? vscode.window.activeTextEditor : undefined));
    assert.strictEqual(editor.selection.active.line, expectedLine, 'cursor on the most relevant lines');
  });

  test('Current File view follows the editor and lists dependents', async () => {
    const client = fileUri('src/api/client.ts');
    await vscode.window.showTextDocument(client);
    await waitFor('the Current File view to load client.ts', () => api.currentFile.uri?.toString() === client.toString() && api.currentFile.fileContext?.file.path === 'src/api/client.ts');
    const roots = api.currentFile.getChildren();
    const items = roots.map((node) => api.currentFile.getTreeItem(node));
    assert.strictEqual(items[0].label, 'Low change risk');
    const usedBy = items.findIndex((item) => item.label === 'Used by');
    assert.ok(usedBy >= 0, `groups: ${items.map((i) => i.label).join(', ')}`);
    const dependents = api.currentFile.getChildren(roots[usedBy]).map((node) => api.currentFile.getTreeItem(node));
    assert.deepStrictEqual(dependents.map((item) => item.resourceUri?.fsPath), [fileUri('src/api/users.ts').fsPath]);
    assert.strictEqual(dependents[0].label, 'users.ts');
    assert.strictEqual(dependents[0].command?.command, 'vesalius.openLocation');

    await vscode.commands.executeCommand('workbench.view.extension.vesalius');
    await screenshot('sidebar');
  });

  test('CodeLens shows "N references · risk <level>" above top-level declarations', async () => {
    const client = await vscode.commands.executeCommand<vscode.CodeLens[]>('vscode.executeCodeLensProvider', fileUri('src/api/client.ts'));
    const ours = client.filter((lens) => lens.command?.command === 'vesalius.showReferencesAt');
    assert.deepStrictEqual(ours.map((lens) => [lens.range.start.line, lens.command?.title]), [[1, '1 reference · risk low']]);

    const invoice = await vscode.commands.executeCommand<vscode.CodeLens[]>('vscode.executeCodeLensProvider', fileUri('src/billing/invoice.ts'));
    assert.deepStrictEqual(
      invoice.filter((lens) => lens.command?.command === 'vesalius.showReferencesAt').map((lens) => [lens.range.start.line, lens.command?.title]),
      [
        [0, '4 references · risk low'],
        [3, '1 reference · risk low'],
        [13, '1 reference · risk low'],
      ],
      'interface, class and function lenses; members get none',
    );
  });

  test('clicking a CodeLens peeks the references', async () => {
    const lenses = await vscode.commands.executeCommand<vscode.CodeLens[]>('vscode.executeCodeLensProvider', fileUri('src/api/client.ts'));
    const lens = lenses.find((l) => l.command?.command === 'vesalius.showReferencesAt');
    assert.ok(lens?.command?.arguments);
    await vscode.window.showTextDocument(fileUri('src/api/client.ts'));
    const locations = await vscode.commands.executeCommand<vscode.Location[]>(lens.command.command, ...lens.command.arguments);
    assert.deepStrictEqual(locations.map((l) => [l.uri.fsPath, l.range.start.line]), [[fileUri('src/api/users.ts').fsPath, 3]]);
    await screenshot('codelens-peek');
    await vscode.commands.executeCommand('closeReferenceSearch');
  });

  test('vesalius.api.findReferences returns Locations in the right file, line and column', async () => {
    const locations = await vscode.commands.executeCommand<vscode.Location[]>('vesalius.api.findReferences', 'ApiClient');
    const site = locations.find((location) => location.uri.fsPath === fileUri('src/api/users.ts').fsPath);
    assert.ok(site, `locations: ${locations.map((l) => l.uri.fsPath).join(', ')}`);
    assert.strictEqual(site.range.start.line, 3);
    assert.strictEqual(site.range.start.character, '  const client = new '.length);
    assert.strictEqual(site.range.end.character - site.range.start.character, 'ApiClient'.length);
  });

  test('Find References (Graph) and Find Callers work from the cursor', async () => {
    const client = await vscode.window.showTextDocument(fileUri('src/api/client.ts'));
    client.selection = new vscode.Selection(1, 15, 1, 15); // inside "ApiClient" in "export class ApiClient {"
    const references = await vscode.commands.executeCommand<vscode.Location[]>('vesalius.findReferences');
    assert.deepStrictEqual(references.map((l) => [l.uri.fsPath, l.range.start.line]), [[fileUri('src/api/users.ts').fsPath, 3]]);
    await vscode.commands.executeCommand('closeReferenceSearch');

    const users = await vscode.window.showTextDocument(fileUri('src/api/users.ts'));
    users.selection = new vscode.Selection(2, 18, 2, 18); // inside "fetchUser"
    const callers = await vscode.commands.executeCommand<vscode.Location[]>('vesalius.findCallers');
    assert.deepStrictEqual(callers.map((l) => [l.uri.fsPath, l.range.start.line, l.range.start.character]), [[fileUri('src/ui/UserCard.tsx').fsPath, 3, 2]]);
    await vscode.commands.executeCommand('closeReferenceSearch');
  });

  test('Show Change Impact opens the Blast Radius panel for a file', async () => {
    const report = await vscode.commands.executeCommand<ImpactReport>('vesalius.showImpact', fileUri('src/api/client.ts'));
    assert.strictEqual(report.target, 'src/api/client.ts');
    assert.strictEqual(report.targetKind, 'file');
    assert.deepStrictEqual(report.directDependents.map((d) => d.path), ['src/api/users.ts']);
    assert.deepStrictEqual(report.transitiveDependents.map((d) => d.path), ['src/ui/UserCard.tsx']);
    const tab = await waitFor('the Blast Radius tab', () => vscode.window.tabGroups.all.flatMap((group) => group.tabs).find((t) => t.label === 'Blast Radius: client.ts'));
    assert.ok(tab.input instanceof vscode.TabInputWebview, 'a webview tab');
    const html = api.impact.html ?? '';
    assert.ok(html.includes('data-path="src/api/users.ts"'), 'dependent paths are clickable');
    assert.ok(html.includes('data-path="src/ui/UserCard.tsx"'), 'transitive paths are clickable');
    assert.ok(!/#[0-9a-fA-F]{3,8}\b|rgb\(/.test(html.slice(html.indexOf('<style'), html.indexOf('</style>'))), 'no hard-coded colors: theme variables only');

    await screenshot('blast-radius-dark');
    if (process.env.VESALIUS_TEST_SCREENSHOTS) {
      const workbench = vscode.workspace.getConfiguration('workbench');
      await workbench.update('colorTheme', 'Light Modern', vscode.ConfigurationTarget.Global);
      await screenshot('blast-radius-light');
      await workbench.update('colorTheme', undefined, vscode.ConfigurationTarget.Global);
    }

    // The message a click on a path posts: it opens the file at the line.
    await api.impact.receive({ type: 'open', path: 'src/api/users.ts', line: 4 });
    const editor = await waitFor('users.ts to open from the panel', () => (vscode.window.activeTextEditor?.document.uri.path.endsWith('src/api/users.ts') ? vscode.window.activeTextEditor : undefined));
    assert.strictEqual(editor.selection.active.line, 3);
  });

  test('Show Change Impact from the cursor targets the declaration', async () => {
    const editor = await vscode.window.showTextDocument(fileUri('src/api/client.ts'), { viewColumn: vscode.ViewColumn.One });
    editor.selection = new vscode.Selection(1, 15, 1, 15);
    const report = await vscode.commands.executeCommand<ImpactReport>('vesalius.showImpact');
    assert.strictEqual(report.targetKind, 'symbol');
    assert.strictEqual(report.target, 'ApiClient');
    assert.deepStrictEqual(report.callers.map((c) => [c.path, c.line]), [['src/api/users.ts', 4]]);
    await waitFor('the panel to retitle', () => vscode.window.tabGroups.all.flatMap((g) => g.tabs).some((t) => t.label === 'Blast Radius: ApiClient'));

    // The Current File view's title button always means the file, wherever the cursor is.
    await waitFor('client.ts in the Current File view', () => api.currentFile.uri?.toString() === fileUri('src/api/client.ts').toString());
    const fileReport = await vscode.commands.executeCommand<ImpactReport>('vesalius.showCurrentFileImpact');
    assert.strictEqual(fileReport.targetKind, 'file');
    assert.strictEqual(fileReport.target, 'src/api/client.ts');
  });

  test('Current File follows a file even when a panel takes focus right after it opens', async () => {
    // The Blast Radius panel sits in the second editor group (opened beside the code above).
    await vscode.window.showTextDocument(fileUri('src/billing/checkout.ts'), { viewColumn: vscode.ViewColumn.One });
    await vscode.commands.executeCommand('workbench.action.focusSecondEditorGroup');
    assert.strictEqual(vscode.window.activeTextEditor, undefined, 'the webview has focus');
    await waitFor('checkout.ts in the Current File view', () => api.currentFile.fileContext?.file.path === 'src/billing/checkout.ts');
  });

  test('Show File Context loads a file into the Current File view', async () => {
    const context = await vscode.commands.executeCommand<FileContext>('vesalius.showFileContext', fileUri('src/billing/invoice.ts'));
    assert.strictEqual(context.file.path, 'src/billing/invoice.ts');
    assert.ok(context.symbols.some((s) => s.name === 'InvoiceCalculator'));
    assert.strictEqual(api.currentFile.uri?.toString(), fileUri('src/billing/invoice.ts').toString());
  });

  test('status bar, Health view and Show Repository Health agree on the score', async () => {
    const health = await vscode.commands.executeCommand<HealthResult>('vesalius.showHealth');
    assert.ok(health && Number.isFinite(health.health.score));
    assert.strictEqual(api.statusBar.item.text, `$(pulse) Health ${health.health.score}`);
    assert.strictEqual(api.statusBar.item.command, 'vesalius.showHealth');
    const tooltip = api.statusBar.item.tooltip as vscode.MarkdownString;
    assert.ok(tooltip.value.includes(health.health.grade) && tooltip.value.includes('| Cycles |'), tooltip.value);

    const roots = api.health.getChildren();
    const summary = api.health.getTreeItem(roots[0]);
    assert.strictEqual(summary.label, `Health ${health.health.score} · ${health.health.grade}`);
    const breakdown = roots.find((node) => node.type === 'categories');
    assert.ok(breakdown);
    assert.strictEqual(api.health.getChildren(breakdown).length, 8, 'eight categories');
  });

  test('Hotspots view ranks the large file first', async () => {
    api.hotspots.invalidate();
    const roots = await api.hotspots.getChildren();
    const first = api.hotspots.getTreeItem(roots[0]);
    assert.strictEqual(first.label, 'bigReport.ts');
    assert.strictEqual(first.resourceUri?.fsPath, fileUri('src/legacy/bigReport.ts').fsPath);
  });

  test('Copy MCP Config produces a config that starts a working MCP server', async () => {
    const saved = await vscode.env.clipboard.readText();
    try {
      await copyAndStartMcpServer();
    } finally {
      await vscode.env.clipboard.writeText(saved);
    }
  });

  async function copyAndStartMcpServer(): Promise<void> {
    const text = await vscode.commands.executeCommand<string>('vesalius.copyMcpConfig', 'json');
    assert.strictEqual(await vscode.env.clipboard.readText(), text, 'copied to the clipboard');
    const config = JSON.parse(text) as { mcpServers: { vesalius: { command: string; args: string[]; env?: Record<string, string> } } };
    const server = config.mcpServers.vesalius;
    assert.strictEqual(server.command, process.env.VESALIUS_CLI_PATH);
    assert.deepStrictEqual(server.args, ['mcp', '--repo', workspaceFolder().fsPath]);

    const exchange = await mcpHandshake(server.command, server.args, server.env ?? {}, { name: 'usages', arguments: { target: 'ApiClient' } });
    assert.strictEqual(exchange.serverName, 'vesalius');
    assert.ok(exchange.tools.includes('usages') && exchange.tools.includes('feature_map'), exchange.tools.join(', '));
    assert.ok(exchange.call?.includes('src/api/users.ts'), 'the server answers about this workspace');

    for (const format of ['claude', 'codex', 'vscode']) {
      const other = await vscode.commands.executeCommand<string>('vesalius.copyMcpConfig', format);
      assert.ok(other.includes(workspaceFolder().fsPath), `${format} config names the folder`);
    }
  }

  test('MCP server definition provider is registered when VS Code supports it', () => {
    const supported = typeof (vscode as any).lm?.registerMcpServerDefinitionProvider === 'function';
    console.log(`      VS Code ${vscode.version}: MCP API ${supported ? 'available' : 'absent'}, provider registered: ${api.mcp.registered}`);
    assert.strictEqual(api.mcp.registered, supported, `VS Code ${vscode.version}`);
    const [launch] = api.mcp.launches();
    assert.strictEqual(launch.label, 'Vesalius');
    assert.strictEqual(launch.command, process.env.VESALIUS_CLI_PATH);
    assert.deepStrictEqual(launch.args, ['mcp', '--repo', workspaceFolder().fsPath]);
  });

  test('vesalius.codeLens.enabled turns the lenses off and on', async () => {
    const config = vscode.workspace.getConfiguration('vesalius');
    const ours = async () =>
      (await vscode.commands.executeCommand<vscode.CodeLens[]>('vscode.executeCodeLensProvider', fileUri('src/api/client.ts'))).filter((l) => l.command?.command === 'vesalius.showReferencesAt');
    await config.update('codeLens.enabled', false, vscode.ConfigurationTarget.Global);
    try {
      assert.deepStrictEqual(await ours(), []);
    } finally {
      await config.update('codeLens.enabled', undefined, vscode.ConfigurationTarget.Global);
    }
    assert.strictEqual((await ours()).length, 1);
  });

  test('the status bar spins while the index updates, then shows the score again', async () => {
    const repository = api.repositories.all[0];
    const seen: string[] = [];
    const subscription = repository.onDidChangeIndexing((indexing) => seen.push(`${indexing}:${api.statusBar.item.text}`));
    try {
      await vscode.commands.executeCommand('vesalius.updateIndex');
    } finally {
      subscription.dispose();
    }
    assert.match(seen[0] ?? '', /^true:\$\(sync~spin\) Health \d+$/, seen.join(' | '));
    assert.match(api.statusBar.item.text, /^\$\(pulse\) Health \d+$/);
  });

  test('view refresh buttons reload Health, Current File and Hotspots', async () => {
    await vscode.window.showTextDocument(fileUri('src/api/users.ts'));
    await waitFor('users.ts in the Current File view', () => api.currentFile.fileContext?.file.path === 'src/api/users.ts');
    for (const command of ['vesalius.refreshHealth', 'vesalius.refreshCurrentFile', 'vesalius.refreshHotspots']) {
      await vscode.commands.executeCommand(command);
    }
    assert.ok(api.health.current, 'health still loaded');
    assert.strictEqual(api.currentFile.fileContext?.file.path, 'src/api/users.ts');
    assert.ok((await api.hotspots.getChildren()).length > 0);
  });

  test('Vesalius: Rebuild Index rebuilds from scratch', async () => {
    const summary = await vscode.commands.executeCommand<IndexSummary>('vesalius.rebuildIndex');
    assert.strictEqual(summary.filesAdded, 12);
    assert.ok(vesaliusDiagnostics(fileUri('src/cycle/a.ts')).length > 0, 'findings are back after the rebuild');
  });

  test('saving a file re-indexes it and refreshes references, views and lenses', async () => {
    const repository = api.repositories.all[0];
    const generation = repository.generation;
    const document = await vscode.workspace.openTextDocument(fileUri('src/ui/UserCard.tsx'));
    const editor = await vscode.window.showTextDocument(document);
    await editor.edit((edit) => edit.insert(new vscode.Position(0, 0), "import { ApiClient } from '../api/client';\nexport const sharedClient = new ApiClient('https://example.com');\n"));
    await document.save();
    await waitFor('the index-on-save update', () => repository.generation > generation);
    await api.ready;

    const locations = await vscode.commands.executeCommand<vscode.Location[]>('vesalius.api.findReferences', 'ApiClient');
    assert.ok(
      locations.some((l) => l.uri.fsPath === fileUri('src/ui/UserCard.tsx').fsPath && l.range.start.line === 1),
      `references now include the new use: ${locations.map((l) => `${l.uri.fsPath}:${l.range.start.line}`).join(', ')}`,
    );
    const lenses = await vscode.commands.executeCommand<vscode.CodeLens[]>('vscode.executeCodeLensProvider', fileUri('src/api/client.ts'));
    assert.strictEqual(lenses.find((lens) => lens.command?.command === 'vesalius.showReferencesAt')?.command?.title.split(' · ')[0], '2 references');

    await vscode.window.showTextDocument(fileUri('src/api/client.ts'));
    await waitFor('client.ts dependents to include UserCard.tsx', () => api.currentFile.fileContext?.dependents.some((d) => d.path === 'src/ui/UserCard.tsx'));
  });
});
