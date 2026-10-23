import * as assert from 'assert';
import * as fs from 'fs';
import * as vscode from 'vscode';
import type { VesaliusApi } from '../../extension';
import type { AskResult, FileContext, ImpactReport, IndexSummary, SymbolSummary } from '../../types';
import { parseLines } from '../../types';
import { activateExtension, fileUri, mcpHandshake, vesaliusDiagnostics, waitFor, workspaceFolder } from './helpers';

// Runs inside a real VS Code on an existing repository (VESALIUS_TEST_REPO) with the real CLI.
// Read only: nothing here edits, saves or creates files in the repository. The runner compares
// `git status` before and after to prove it.

const lensTitle = /^\d+ references? · risk (low|moderate|high|critical)$/;

suite('Vesalius: real repository', () => {
  let api: VesaliusApi;
  let hub: FileContext;

  suiteSetup(async () => {
    api = await activateExtension();
  });

  test('indexes the repository with the real CLI', async () => {
    const summary = await vscode.commands.executeCommand<IndexSummary>('vesalius.updateIndex');
    assert.ok(summary, 'Update Index returned a summary');
    console.log(`      indexed ${summary.filesScanned} files, ${summary.symbols} symbols, ${summary.references} references, ${summary.edges} edges`);
    assert.ok(summary.filesScanned > 20, `filesScanned ${summary.filesScanned}`);
    assert.ok(summary.symbols > 100);
    assert.ok(summary.indexPath.startsWith(process.env.VESALIUS_HOME ?? '\0'), 'index lives in VESALIUS_HOME');
  });

  test('every medium+ finding with a file appears in the Problems panel', async () => {
    const repository = api.repositories.all[0];
    const findings = (await repository.diagnostics('medium')).filter((f) => f.targets.some((t) => t.kind === 'file' || t.kind === 'symbol'));
    console.log(`      ${findings.length} medium+ findings with file targets`);
    for (const finding of findings.slice(0, 40)) {
      const target = finding.targets.find((t) => t.kind === 'file' || t.kind === 'symbol');
      assert.ok(target);
      const shown = await waitFor(`"${finding.title}" on ${target.path}`, () => vesaliusDiagnostics(fileUri(target.path)).find((d) => d.message === finding.title && d.code === finding.rule));
      if (target.line) {
        const lines = finding.targets.filter((t) => t.path === target.path && t.line).map((t) => (t.line ?? 0) - 1);
        assert.ok(lines.includes(shown.range.start.line), `${finding.title} placed on a named line`);
      }
    }
  });

  test('status bar and Health view show the repository score', async () => {
    await api.ready;
    const result = api.health.current;
    assert.ok(result, 'health loaded');
    assert.strictEqual(api.statusBar.item.text, `$(pulse) Health ${result.health.score}`);
    console.log(`      health ${result.health.score} (${result.health.grade})`);
    const summary = api.health.getTreeItem(api.health.getChildren()[0]);
    assert.strictEqual(summary.label, `Health ${result.health.score} · ${result.health.grade}`);
  });

  test('Current File view shows the most depended-on hotspot and its dependents', async () => {
    const repository = api.repositories.all[0];
    const hotspots = await repository.hotspots();
    assert.ok(hotspots.length > 0, 'hotspots');
    const busiest = [...hotspots].sort((a, b) => b.fanIn - a.fanIn)[0];
    await vscode.window.showTextDocument(fileUri(busiest.path), { preview: true });
    await waitFor(`the Current File view to load ${busiest.path}`, () => api.currentFile.fileContext?.file.path === busiest.path);
    hub = api.currentFile.fileContext as FileContext;
    console.log(`      ${busiest.path}: ${hub.dependents.length} direct dependents, ${hub.symbols.length} symbols`);

    const roots = api.currentFile.getChildren();
    const usedBy = roots.find((node) => node.type === 'group' && node.group === 'dependents');
    assert.ok(usedBy);
    const shown = api.currentFile.getChildren(usedBy).map((node) => api.currentFile.getTreeItem(node).resourceUri?.fsPath);
    assert.deepStrictEqual(shown, hub.dependents.map((d) => fileUri(d.path).fsPath));
    shown.forEach((file) => assert.ok(file && fs.existsSync(file), `${file} exists`));
  });

  test('CodeLens titles and positions line up with the real declarations', async () => {
    const document = await vscode.workspace.openTextDocument(fileUri(hub.file.path));
    const lenses = (await vscode.commands.executeCommand<vscode.CodeLens[]>('vscode.executeCodeLensProvider', document.uri)).filter((l) => l.command?.command === 'vesalius.showReferencesAt');
    const topLevel = hub.symbols.filter((s) => (s.depth ?? 0) === 0 && ['class', 'struct', 'enum', 'protocol', 'interface', 'actor', 'typealias', 'function', 'component'].includes(s.kind));
    assert.strictEqual(lenses.length, topLevel.length, 'one lens per top-level type or function');
    for (const lens of lenses) {
      assert.match(lens.command?.title ?? '', lensTitle);
      const [, position, , name] = lens.command?.arguments ?? [];
      const line = document.lineAt((position as vscode.Position).line).text;
      assert.ok(line.includes(name as string), `lens for ${name} sits on its declaration: "${line.trim()}"`);
    }
  });

  test('Find References locations point at the symbol on real lines', async () => {
    const symbol = hub.symbols.find((s) => (s.depth ?? 0) === 0 && (s.references ?? 0) > 0) as SymbolSummary | undefined;
    assert.ok(symbol, 'a referenced top-level symbol');
    const locations = await vscode.commands.executeCommand<vscode.Location[]>('vesalius.api.findReferences', symbol.id);
    console.log(`      ${symbol.name}: ${locations.length} references`);
    assert.ok(locations.length > 0);
    for (const location of locations.slice(0, 50)) {
      const document = await vscode.workspace.openTextDocument(location.uri);
      const text = document.getText(location.range);
      assert.strictEqual(text, symbol.name, `${location.uri.fsPath}:${location.range.start.line + 1} highlights "${text}"`);
    }
  });

  test('overloads (ids ending in ~2) resolve to their own references and blast radius', async function () {
    const repository = api.repositories.all[0];
    const files = await vscode.workspace.findFiles('**/*.{swift,ts,tsx,js,py,kt,go,rs,java}', '{**/.build/**,**/node_modules/**,**/DerivedData/**}', 300);
    let overload: SymbolSummary | undefined;
    for (const file of files) {
      const relative = repository.relativePath(file);
      const context = relative ? await repository.fileContext(relative) : undefined;
      overload = context?.symbols.find((s) => /~\d+$/.test(s.id) && (s.references ?? 0) > 0);
      if (overload) {
        break;
      }
    }
    if (!overload) {
      console.log('      no referenced overload in this repository');
      this.skip();
      return;
    }
    console.log(`      ${overload.id}: ${overload.references} references`);
    const locations = await vscode.commands.executeCommand<vscode.Location[]>('vesalius.api.findReferences', overload.id);
    assert.ok(locations.length > 0);
    for (const location of locations.slice(0, 20)) {
      const document = await vscode.workspace.openTextDocument(location.uri);
      assert.strictEqual(document.getText(location.range), overload.name);
    }
    const report = await vscode.commands.executeCommand<ImpactReport>('vesalius.showImpact', fileUri(overload.path), overload.id);
    assert.strictEqual(report.targetKind, 'symbol');
    await waitFor('the panel titled without the ~N suffix', () => vscode.window.tabGroups.all.flatMap((g) => g.tabs).some((t) => t.label === `Blast Radius: ${overload?.qualifiedName}`));
  });

  test('Ask finds the file that defines a named type', async () => {
    const type = hub.symbols.find((s) => (s.depth ?? 0) === 0 && ['class', 'struct', 'enum', 'protocol', 'actor'].includes(s.kind));
    assert.ok(type, 'a top-level type in the hub file');
    const result = await vscode.commands.executeCommand<AskResult>('vesalius.api.ask', `where is ${type.name} defined?`);
    const paths = result.files.map((f) => f.path);
    console.log(`      "where is ${type.name} defined?" → ${paths.slice(0, 3).join(', ')}`);
    assert.ok(paths.slice(0, 3).includes(hub.file.path), `top 3: ${paths.slice(0, 3).join(', ')}`);
    paths.forEach((p) => assert.ok(fs.existsSync(fileUri(p).fsPath), `${p} exists`));
  });

  test('Blast Radius for the hub file matches its direct dependents', async () => {
    const report = await vscode.commands.executeCommand<ImpactReport>('vesalius.showImpact', fileUri(hub.file.path));
    assert.strictEqual(report.target, hub.file.path);
    assert.deepStrictEqual(report.directDependents.map((d) => d.path).sort(), hub.dependents.map((d) => d.path).sort());
    console.log(`      ${report.riskLevel} risk (${Math.round(report.riskScore)}/100): ${report.directDependents.length} direct, ${report.transitiveDependents.length} transitive`);
    assert.ok(api.impact.html?.includes(`data-path="${report.directDependents[0]?.path ?? ''}"`));
  });

  test('the MCP server from Copy MCP Config answers about this repository', async () => {
    const saved = await vscode.env.clipboard.readText();
    try {
      const config = JSON.parse(await vscode.commands.executeCommand<string>('vesalius.copyMcpConfig', 'json'));
      const server = config.mcpServers.vesalius;
      assert.deepStrictEqual(server.args, ['mcp', '--repo', workspaceFolder().fsPath]);
      const exchange = await mcpHandshake(server.command, server.args, server.env ?? {}, { name: 'outline', arguments: { target: hub.file.path } });
      assert.ok(exchange.tools.includes('outline') && exchange.tools.includes('usages'), exchange.tools.join(', '));
      assert.ok(exchange.call?.includes(hub.file.path), 'outline answers for the hub file');
    } finally {
      await vscode.env.clipboard.writeText(saved);
    }
  });

  test('symbol lines from the index match the files on disk', () => {
    for (const symbol of hub.symbols.filter((s) => (s.depth ?? 0) === 0).slice(0, 20)) {
      const range = parseLines(symbol.lines);
      assert.ok(range);
      const text = fs.readFileSync(fileUri(symbol.path).fsPath, 'utf8').split(/\r?\n/)[range.start - 1] ?? '';
      assert.ok(text.includes(symbol.name), `${symbol.name} at ${symbol.path}:${range.start}: "${text.trim()}"`);
    }
  });
});
