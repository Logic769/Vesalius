import * as vscode from 'vscode';
import { Vesalius } from './controller';
import { McpServerLaunch } from './mcp';
import { Repository } from './repository';
import { AskFile, AskResult, CallGraphResult, ImpactReport, IndexSummary, parseLines, ReferencesResult, SymbolSummary } from './types';
import { LineReader, openLocation, plural, splitPath, symbolLabel, wordAtCursor } from './util';

const askHistoryKey = 'vesalius.askHistory';

/** Registers every `vesalius.*` command. UI commands report failures; `vesalius.api.*` rethrow them. */
export function registerCommands(v: Vesalius): vscode.Disposable[] {
  // Command arguments arrive untyped from menus, CodeLens and other extensions.
  type Handler = (...args: any[]) => unknown;
  const ui = (id: string, handler: Handler) =>
    vscode.commands.registerCommand(id, async (...args: unknown[]) => {
      try {
        return await handler(...args);
      } catch (error) {
        await v.showError(error);
        return undefined;
      }
    });
  const api = (id: string, handler: Handler) => vscode.commands.registerCommand(id, handler);

  return [
    ui('vesalius.ask', (question?: string) => ask(v, typeof question === 'string' ? question : undefined)),
    // From the palette (no arguments) and the editor's context menu the cursor picks the target:
    // a declaration under the cursor, else the file. From the explorer or a tab it is the file.
    ui('vesalius.showImpact', (target?: unknown, symbolID?: string) => showImpact(v, asUri(target), typeof symbolID === 'string' ? symbolID : undefined, target === undefined)),
    ui('vesalius.showImpactAtCursor', (target?: unknown) => showImpact(v, asUri(target), undefined, true)),
    ui('vesalius.showCurrentFileImpact', () => showImpact(v, v.currentFile.uri, undefined, false)),
    ui('vesalius.findReferences', (uri?: unknown, position?: unknown) => findReferences(v, 'references', uri, position)),
    ui('vesalius.findCallers', (uri?: unknown, position?: unknown) => findReferences(v, 'callers', uri, position)),
    ui('vesalius.showReferencesAt', (uri: vscode.Uri, position: vscode.Position, symbolID: string, name: string) => showReferencesAt(v, uri, position, symbolID, name)),
    ui('vesalius.showFileContext', (target?: unknown) => showFileContext(v, target)),
    ui('vesalius.updateIndex', () => updateIndex(v, false)),
    ui('vesalius.rebuildIndex', () => updateIndex(v, true)),
    ui('vesalius.showHealth', async () => {
      await vscode.commands.executeCommand('vesalius.health.focus');
      await v.refreshHealth();
      return v.health.current;
    }),
    ui('vesalius.openInApp', (target?: unknown) => {
      const uri = target instanceof vscode.Uri ? target : vscode.window.activeTextEditor?.document.uri;
      const repository = requireRepository(v, uri);
      const file = uri ? repository.relativePath(uri) : undefined;
      return v.openInApp(repository, { file });
    }),
    ui('vesalius.copyMcpConfig', (format?: string) => copyMcpConfig(v, typeof format === 'string' ? format : undefined)),
    ui('vesalius.installCli', () => v.installCli()),
    ui('vesalius.showOutput', () => v.log.show(true)),
    ui('vesalius.refreshHealth', () => reindexThen(v, () => v.refreshHealth())),
    ui('vesalius.refreshCurrentFile', () => reindexThen(v, () => v.currentFile.refresh())),
    ui('vesalius.refreshHotspots', () => reindexThen(v, async () => v.hotspots.invalidate())),
    ui('vesalius.openLocation', (uri: vscode.Uri, line?: number) => openLocation(uri, line)),
    api('vesalius.api.ask', (question: string, folder?: vscode.Uri) => requireRepository(v, folder).ask(question)),
    api('vesalius.api.findReferences', async (symbol: string, folder?: vscode.Uri) => {
      const repository = requireRepository(v, folder);
      return referenceLocations(repository, await repository.references(symbol), symbol);
    }),
  ];
}

function asUri(value: unknown): vscode.Uri | undefined {
  return value instanceof vscode.Uri ? value : undefined;
}

function requireRepository(v: Vesalius, uri?: vscode.Uri): Repository {
  const repository = (uri && v.repositories.for(uri)) || v.repositories.active;
  if (!repository) {
    throw new Error('Open a folder to use Vesalius.');
  }
  return repository;
}

/** Incrementally re-indexes the active folder, then reloads a view if the index did not change. */
async function reindexThen(v: Vesalius, reload: () => Promise<void>): Promise<void> {
  const repository = v.repositories.active;
  if (!repository) {
    return;
  }
  const before = repository.generation;
  await v.index(repository);
  await v.settle();
  if (repository.generation === before) {
    await reload();
  }
}

// MARK: Index

async function updateIndex(v: Vesalius, rebuild: boolean): Promise<IndexSummary | undefined> {
  const repositories = v.repositories.all;
  if (repositories.length === 0) {
    void vscode.window.showInformationMessage('Open a folder to index it with Vesalius.');
    return undefined;
  }
  v.cli(); // Fail fast with install guidance when the CLI is missing.
  const active = v.repositories.active ?? repositories[0];
  return vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: rebuild ? 'Vesalius: Rebuilding index' : 'Vesalius: Updating index', cancellable: true },
    async (progress, token) => {
      let result: IndexSummary | undefined;
      for (const repository of repositories) {
        progress.report({ message: repositories.length > 1 ? repository.folder.name : undefined });
        const summary = await v.index(repository, { rebuild, token });
        if (repository === active) {
          result = summary;
        }
      }
      progress.report({ message: 'Refreshing views…' });
      await v.settle();
      if (result) {
        const updated = result.filesAdded + result.filesChanged + result.filesRemoved;
        const detail = rebuild || updated > 0 ? `${plural(updated, 'file')} updated` : 'up to date';
        vscode.window.setStatusBarMessage(`$(check) Vesalius: ${plural(result.filesScanned, 'file')} indexed, ${detail} (${result.durationSeconds.toFixed(1)} s)`, 5000);
        if (result.filesFailed > 0) {
          void vscode.window.showWarningMessage(`Vesalius could not read ${plural(result.filesFailed, 'file')}. See the output log for details.`, 'Show Log').then((choice) => choice && v.log.show(true));
        }
      }
      return result;
    },
  );
}

// MARK: Ask

interface AskItem extends vscode.QuickPickItem {
  kind?: vscode.QuickPickItemKind;
  action?: 'ask' | 'history';
  question?: string;
  file?: AskFile;
}

async function ask(v: Vesalius, initialQuestion?: string): Promise<AskResult | undefined> {
  const repository = requireRepository(v, vscode.window.activeTextEditor?.document.uri);
  v.cli();
  const history = v.context.workspaceState.get<string[]>(askHistoryKey, []);
  const pick = vscode.window.createQuickPick<AskItem>();
  pick.title = 'Ask the Codebase';
  pick.placeholder = 'Ask in plain words, e.g. "where are invoice totals calculated?"';
  pick.matchOnDescription = false;
  pick.matchOnDetail = false;
  const appButton: vscode.QuickInputButton = { iconPath: new vscode.ThemeIcon('link-external'), tooltip: 'Ask in the Vesalius app' };
  const impactButton: vscode.QuickInputButton = { iconPath: new vscode.ThemeIcon('pulse'), tooltip: 'Show change impact' };

  let results: AskItem[] = [];
  let lastResult: AskResult | undefined;
  let asked: string | undefined;

  const render = () => {
    const value = pick.value.trim();
    const items: AskItem[] = [];
    if (value && value !== asked) {
      items.push({ label: `$(sparkle) Ask “${value}”`, action: 'ask', question: value, alwaysShow: true });
    }
    if (results.length > 0) {
      items.push({ label: 'Most relevant files', kind: vscode.QuickPickItemKind.Separator }, ...results);
    }
    const recent = history.filter((question) => question !== asked).slice(0, 6);
    if (recent.length > 0 && results.length === 0) {
      items.push({ label: 'Recent questions', kind: vscode.QuickPickItemKind.Separator });
      items.push(...recent.map((question) => ({ label: `$(history) ${question}`, action: 'history' as const, question })));
    }
    pick.items = items;
  };

  const run = async (question: string) => {
    asked = question;
    pick.busy = true;
    pick.title = `Asking: ${question}`;
    render();
    try {
      const result = await repository.ask(question);
      lastResult = result;
      results = result.files.map((file) => resultItem(file, impactButton));
      pick.title = result.files.length > 0 ? result.answer : `No confident answer for “${question}”`;
      pick.buttons = [appButton];
      const updated = [question, ...history.filter((q) => q !== question)].slice(0, 20);
      history.splice(0, history.length, ...updated);
      void v.context.workspaceState.update(askHistoryKey, updated);
      pick.value = '';
      render();
      const first = pick.items.find((item) => item.file);
      if (first) {
        pick.activeItems = [first];
      }
      v.answered.fire(result);
    } catch (error) {
      pick.title = 'Ask the Codebase';
      results = [];
      render();
      void v.showError(error);
    } finally {
      pick.busy = false;
    }
  };

  return new Promise<AskResult | undefined>((resolve) => {
    pick.onDidChangeValue(render);
    pick.onDidAccept(async () => {
      const item = pick.activeItems[0] ?? pick.selectedItems[0];
      if (item?.file) {
        pick.hide();
        await openAskResult(repository, item.file);
        return;
      }
      const question = item?.question ?? pick.value.trim();
      if (question) {
        pick.value = question;
        await run(question);
      }
    });
    pick.onDidTriggerItemButton(async (event) => {
      if (event.item.file) {
        pick.hide();
        await v.impact.show(repository, event.item.file.path, splitPath(event.item.file.path).name).catch((error) => v.showError(error));
      }
    });
    pick.onDidTriggerButton(async () => {
      if (asked) {
        pick.hide();
        await v.openInApp(repository, { ask: asked });
      }
    });
    pick.onDidHide(() => {
      pick.dispose();
      resolve(lastResult);
    });
    render();
    pick.show();
    if (initialQuestion?.trim()) {
      pick.value = initialQuestion.trim();
      void run(initialQuestion.trim());
    }
  });
}

function resultItem(file: AskFile, impactButton: vscode.QuickInputButton): AskItem {
  const { name, directory } = splitPath(file.path);
  // The reason often names the symbols already; repeat them only when it does not.
  const symbols = file.symbols.slice(0, 4).map((symbol) => symbol.name).filter((name) => !file.reason.includes(name));
  const relevance = Math.round(file.relevance * 100);
  return {
    label: `$(file-code) ${name}`,
    description: directory,
    detail: [file.reason, symbols.length > 0 ? symbols.join(', ') : undefined, Number.isFinite(relevance) ? `${relevance}% match` : undefined].filter(Boolean).join('  ·  '),
    file,
    alwaysShow: true,
    buttons: [impactButton],
  };
}

async function openAskResult(repository: Repository, file: AskFile): Promise<void> {
  const range = parseLines(file.lines) ?? parseLines(file.symbols[0]?.lines);
  await openLocation(repository.uri(file.path), range?.start, range?.end);
}

// MARK: Impact

async function showImpact(v: Vesalius, uri: vscode.Uri | undefined, symbolID: string | undefined, followCursor: boolean): Promise<ImpactReport | undefined> {
  const editor = vscode.window.activeTextEditor;
  const fileUri = uri ?? editor?.document.uri;
  if (!fileUri) {
    const repository = requireRepository(v);
    const typed = await vscode.window.showInputBox({ title: 'Show Change Impact', prompt: 'A file path or symbol name', placeHolder: 'src/billing/invoice.ts or InvoiceCalculator' });
    return typed?.trim() ? v.impact.show(repository, typed.trim(), typed.trim()) : undefined;
  }
  const repository = v.repositories.for(fileUri);
  const relativePath = repository?.relativePath(fileUri);
  if (!repository || !relativePath) {
    throw new Error('This file is not inside a workspace folder that Vesalius indexes.');
  }
  if (symbolID) {
    return v.impact.show(repository, symbolID, symbolLabel(symbolID));
  }
  if (followCursor && editor && editor.document.uri.toString() === fileUri.toString()) {
    const symbol = await declarationAtCursor(repository, relativePath, editor);
    if (symbol) {
      return v.impact.show(repository, symbol.id, symbol.qualifiedName);
    }
  }
  return v.impact.show(repository, relativePath, splitPath(relativePath).name);
}

/** The declaration whose name the cursor is on, when the cursor sits on its declaring line. */
async function declarationAtCursor(repository: Repository, relativePath: string, editor: vscode.TextEditor): Promise<SymbolSummary | undefined> {
  const word = wordAtCursor(editor);
  if (!word) {
    return undefined;
  }
  const context = await repository.fileContext(relativePath);
  const line = editor.selection.active.line + 1;
  return context?.symbols.find((symbol) => symbol.name === word && parseLines(symbol.lines)?.start === line);
}

// MARK: References and callers

async function findReferences(v: Vesalius, mode: 'references' | 'callers', uriArgument?: unknown, positionArgument?: unknown): Promise<vscode.Location[] | undefined> {
  const editor = vscode.window.activeTextEditor;
  let uri = uriArgument instanceof vscode.Uri ? uriArgument : editor?.document.uri;
  let position = positionArgument instanceof vscode.Position ? positionArgument : editor?.selection.active;
  let query: string | undefined;
  let repository = uri ? v.repositories.for(uri) : undefined;

  if (editor && uri && editor.document.uri.toString() === uri.toString()) {
    const word = wordAtCursor(editor);
    const relativePath = repository?.relativePath(uri);
    if (word && repository && relativePath) {
      // Prefer the exact declaration in this file over every symbol that shares the name.
      const context = await repository.fileContext(relativePath).catch(() => undefined);
      const line = editor.selection.active.line + 1;
      const candidates = context?.symbols.filter((symbol) => symbol.name === word) ?? [];
      const declared = candidates.find((symbol) => {
        const lines = parseLines(symbol.lines);
        return lines !== undefined && line >= lines.start && line <= lines.end;
      }) ?? (candidates.length === 1 ? candidates[0] : undefined);
      query = declared?.id ?? word;
    } else {
      query = word;
    }
  }
  if (!query) {
    query = (await vscode.window.showInputBox({ title: mode === 'references' ? 'Find References (Graph)' : 'Find Callers', prompt: 'Symbol name', placeHolder: 'ApiClient or InvoiceCalculator.total' }))?.trim();
    if (!query) {
      return undefined;
    }
    uri = undefined;
    position = undefined;
  }
  repository = repository ?? requireRepository(v);
  const name = symbolLabel(query);
  let locations: vscode.Location[];
  if (mode === 'references') {
    const result = await repository.references(query);
    locations = referenceLocations(repository, result, name);
    noteTruncation(result, locations.length);
  } else {
    locations = callerLocations(repository, await repository.callers(query), name);
  }
  await present(repository, locations, uri, position, `${mode === 'references' ? 'References to' : 'Callers of'} ${name}`);
  return locations;
}

/** The CLI caps reference lists; say so when the peek shows only part of them. */
function noteTruncation(result: ReferencesResult, shown: number): void {
  if (result.total > shown && shown > 0) {
    vscode.window.setStatusBarMessage(`$(info) Vesalius: showing ${shown} of ${result.total} references`, 6000);
  }
}

async function showReferencesAt(v: Vesalius, uri: vscode.Uri, position: vscode.Position, symbolID: string, name: string): Promise<vscode.Location[]> {
  const repository = requireRepository(v, uri);
  const result = await repository.references(symbolID);
  const locations = referenceLocations(repository, result, name);
  noteTruncation(result, locations.length);
  await present(repository, locations, uri, position, `References to ${name}`);
  return locations;
}

function referenceLocations(repository: Repository, result: ReferencesResult, query: string): vscode.Location[] {
  const reader = new LineReader();
  const name = result.symbols[0]?.name ?? query;
  const sites = result.references.length > 0 ? result.references : result.textualMatches ?? [];
  return sites.map((site) => {
    const uri = repository.uri(site.path);
    return new vscode.Location(uri, reader.nameRange(uri, site.line, name));
  });
}

function callerLocations(repository: Repository, result: CallGraphResult, query: string): vscode.Location[] {
  const reader = new LineReader();
  const name = result.symbols[0]?.name ?? query;
  return result.relations.flatMap((relation) =>
    relation.sites.map((line) => {
      const uri = repository.uri(relation.symbol.path);
      return new vscode.Location(uri, reader.nameRange(uri, line, name));
    }),
  );
}

/** Peeks locations inline when there is an anchor in an editor, else offers them in a picker. */
async function present(repository: Repository, locations: vscode.Location[], uri: vscode.Uri | undefined, position: vscode.Position | undefined, title: string): Promise<void> {
  if (locations.length === 0) {
    void vscode.window.showInformationMessage(`Vesalius: no ${title.toLowerCase()} in the index.`);
    return;
  }
  if (uri && position) {
    await vscode.commands.executeCommand('editor.action.showReferences', uri, position, locations);
    return;
  }
  const reader = new LineReader();
  const picked = await vscode.window.showQuickPick(
    locations.map((location) => {
      const relativePath = repository.relativePath(location.uri) ?? location.uri.fsPath;
      return {
        label: `${splitPath(relativePath).name}:${location.range.start.line + 1}`,
        description: splitPath(relativePath).directory,
        detail: (reader.lines(location.uri)[location.range.start.line] ?? '').trim(),
        location,
      };
    }),
    { title, matchOnDescription: true, matchOnDetail: true },
  );
  if (picked) {
    await openLocation(picked.location.uri, picked.location.range.start.line + 1);
  }
}

// MARK: File context

async function showFileContext(v: Vesalius, target: unknown) {
  const uri = target instanceof vscode.Uri ? target : vscode.window.activeTextEditor?.document.uri;
  await vscode.commands.executeCommand('vesalius.currentFile.focus');
  await v.currentFile.load(uri);
  return v.currentFile.fileContext;
}

// MARK: MCP

const mcpFormats = [
  { id: 'json', label: 'JSON', description: 'Claude Desktop, Cursor, Windsurf and most MCP clients' },
  { id: 'claude', label: 'Claude Code', description: 'claude mcp add command' },
  { id: 'codex', label: 'Codex', description: '~/.codex/config.toml' },
  { id: 'vscode', label: 'VS Code', description: '.vscode/mcp.json' },
];

async function copyMcpConfig(v: Vesalius, format?: string): Promise<string | undefined> {
  v.cli();
  const launches = v.mcp.launches();
  const active = v.repositories.active;
  const launch = launches.find((l) => active && l.folder.toString() === active.folder.uri.toString()) ?? launches[0];
  if (!launch) {
    void vscode.window.showInformationMessage('Open a folder to configure the Vesalius MCP server for it.');
    return undefined;
  }
  const chosen = format ?? (await vscode.window.showQuickPick(mcpFormats, { title: 'Copy MCP Config', placeHolder: 'Which client will use the Vesalius MCP server?' }))?.id;
  if (!chosen) {
    return undefined;
  }
  const text = renderMcpConfig(chosen, launch);
  await vscode.env.clipboard.writeText(text);
  const label = mcpFormats.find((f) => f.id === chosen)?.label ?? chosen;
  void vscode.window.showInformationMessage(`Copied the Vesalius MCP config (${label}) for ${launch.folder.fsPath.replace(/^.*\//, '')}.`);
  return text;
}

export function renderMcpConfig(format: string, launch: McpServerLaunch): string {
  const hasEnv = Object.keys(launch.env).length > 0;
  switch (format) {
    case 'claude': {
      const env = Object.entries(launch.env).map(([key, value]) => ` -e ${key}=${shellQuote(value)}`).join('');
      return `claude mcp add vesalius${env} -- ${[launch.command, ...launch.args].map(shellQuote).join(' ')}\n`;
    }
    case 'codex': {
      const lines = ['[mcp_servers.vesalius]', `command = ${JSON.stringify(launch.command)}`, `args = [${launch.args.map((a) => JSON.stringify(a)).join(', ')}]`];
      if (hasEnv) {
        lines.push(`env = { ${Object.entries(launch.env).map(([key, value]) => `${key} = ${JSON.stringify(value)}`).join(', ')} }`);
      }
      return `${lines.join('\n')}\n`;
    }
    case 'vscode':
      return `${JSON.stringify({ servers: { vesalius: { type: 'stdio', command: launch.command, args: launch.args, ...(hasEnv ? { env: launch.env } : {}) } } }, null, 2)}\n`;
    default:
      return `${JSON.stringify({ mcpServers: { vesalius: { command: launch.command, args: launch.args, ...(hasEnv ? { env: launch.env } : {}) } } }, null, 2)}\n`;
  }
}

function shellQuote(value: string): string {
  return /^[\w./:@=+-]+$/.test(value) ? value : `'${value.replace(/'/g, `'\\''`)}'`;
}
