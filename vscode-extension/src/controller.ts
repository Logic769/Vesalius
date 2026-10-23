import { execFile } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import * as vscode from 'vscode';
import { CliError, CliLocation, CliNotFoundError, findAppBinary, resolveCli, VesaliusCli } from './cli';
import { VesaliusCodeLensProvider } from './codeLens';
import { DiagnosticsController } from './diagnostics';
import { ImpactPanel } from './impactPanel';
import { McpRegistration } from './mcp';
import { Repositories, Repository } from './repository';
import { HealthStatusBar } from './statusBar';
import { AskResult, IndexSummary } from './types';
import { errorMessage } from './util';
import { CurrentFileNode, CurrentFileTreeProvider } from './views/currentFileTree';
import { HealthNode, HealthTreeProvider } from './views/healthTree';
import { HotspotsTreeProvider } from './views/hotspotsTree';

const saveDebounceMs = 1500;

/** Owns the CLI, the per-folder repositories and every surface that shows their data. */
export class Vesalius implements vscode.Disposable {
  readonly log = vscode.window.createOutputChannel('Vesalius');
  readonly repositories: Repositories;
  readonly health: HealthTreeProvider;
  readonly currentFile: CurrentFileTreeProvider;
  readonly hotspots: HotspotsTreeProvider;
  readonly diagnostics: DiagnosticsController;
  readonly codeLens: VesaliusCodeLensProvider;
  readonly statusBar = new HealthStatusBar();
  readonly impact: ImpactPanel;
  readonly mcp: McpRegistration;
  readonly healthView: vscode.TreeView<HealthNode>;
  readonly currentFileView: vscode.TreeView<CurrentFileNode>;
  /** Fires when "Ask the Codebase" shows an answer. */
  readonly answered = new vscode.EventEmitter<AskResult>();

  /** Settles once the latest activation or CLI change has indexed every folder and refreshed the views. */
  ready: Promise<void> = Promise.resolve();

  private location: CliLocation | undefined;
  private client: VesaliusCli | undefined;
  private cliError: Error | undefined;
  private cliPrompted = false;
  private readonly wired = new Set<Repository>();
  private readonly refreshes = new Map<Repository, Promise<void>>();
  private readonly saveTimers = new Map<Repository, NodeJS.Timeout>();
  private editorTimer: NodeJS.Timeout | undefined;
  /** The last file editor that became active, even briefly, and the one the view last followed. */
  private lastFileEditor: vscode.Uri | undefined;
  private followedFile: vscode.Uri | undefined;
  private activeRepository: Repository | undefined;
  private readonly disposables: vscode.Disposable[] = [];

  constructor(readonly context: vscode.ExtensionContext) {
    this.repositories = new Repositories(() => this.cli());
    this.health = new HealthTreeProvider(this.repositories);
    this.currentFile = new CurrentFileTreeProvider(this.repositories);
    this.hotspots = new HotspotsTreeProvider(this.repositories);
    this.diagnostics = new DiagnosticsController(this.repositories, this.log);
    this.codeLens = new VesaliusCodeLensProvider(this.repositories);
    this.impact = new ImpactPanel(context.extensionUri, (repository, options) => this.openInApp(repository, options));
    this.mcp = new McpRegistration(this.repositories, () => this.location, this.log);

    this.healthView = vscode.window.createTreeView('vesalius.health', { treeDataProvider: this.health, showCollapseAll: true });
    this.currentFileView = vscode.window.createTreeView('vesalius.currentFile', { treeDataProvider: this.currentFile, showCollapseAll: true });
    this.currentFile.view = this.currentFileView;
    const hotspotsView = vscode.window.createTreeView('vesalius.hotspots', { treeDataProvider: this.hotspots });

    this.disposables.push(
      this.log,
      this.answered,
      this.repositories,
      this.diagnostics,
      this.statusBar,
      this.impact,
      this.mcp,
      this.healthView,
      this.currentFileView,
      hotspotsView,
      vscode.languages.registerCodeLensProvider({ scheme: 'file' }, this.codeLens),
      this.repositories.onDidChange(() => this.onFoldersChanged()),
      vscode.window.onDidChangeActiveTextEditor((editor) => {
        if (editor?.document.uri.scheme === 'file') {
          this.lastFileEditor = editor.document.uri;
        }
        clearTimeout(this.editorTimer);
        this.editorTimer = setTimeout(() => this.onActiveEditorChanged(), 120);
      }),
      vscode.workspace.onDidSaveTextDocument((document) => this.scheduleIndex(document.uri)),
      vscode.workspace.onDidCreateFiles((event) => event.files.forEach((uri) => this.scheduleIndex(uri))),
      vscode.workspace.onDidDeleteFiles((event) => event.files.forEach((uri) => this.scheduleIndex(uri))),
      vscode.workspace.onDidRenameFiles((event) => event.files.forEach((file) => this.scheduleIndex(file.newUri))),
      vscode.workspace.onDidChangeConfiguration((event) => this.onConfigurationChanged(event)),
    );
    this.repositories.all.forEach((repository) => this.wire(repository));
    this.activeRepository = this.repositories.active;
  }

  dispose(): void {
    clearTimeout(this.editorTimer);
    this.saveTimers.forEach((timer) => clearTimeout(timer));
    this.disposables.forEach((d) => d.dispose());
  }

  /** Finds the CLI, then indexes every folder in the background (incremental after the first run). */
  start(): void {
    this.resolveCli();
    this.ready = this.indexAll();
    const editor = vscode.window.activeTextEditor;
    if (editor?.document.uri.scheme === 'file') {
      this.lastFileEditor = editor.document.uri;
    }
    this.follow(this.lastFileEditor);
  }

  // MARK: CLI

  /** Re-resolves the CLI (after settings change or installation). Returns its location, if found. */
  resolveCli(): CliLocation | undefined {
    try {
      const location = resolveCli();
      if (location.command !== this.location?.command) {
        this.log.appendLine(`Using ${location.command}${location.prefixArgs.length ? ` ${location.prefixArgs.join(' ')}` : ''} (${location.source})`);
      }
      this.location = location;
      this.client = new VesaliusCli(location, this.log);
      this.cliError = undefined;
    } catch (error) {
      this.location = undefined;
      this.client = undefined;
      this.cliError = error instanceof Error ? error : new Error(String(error));
      this.log.appendLine(this.cliError.message);
    }
    void vscode.commands.executeCommand('setContext', 'vesalius.cliMissing', !this.client);
    this.statusBar.setCliMissing(!this.client);
    this.mcp.refresh();
    return this.location;
  }

  get cliLocation(): CliLocation | undefined {
    return this.location;
  }

  /** The CLI client; throws CliNotFoundError (after one more lookup) when it is not installed. */
  cli(): VesaliusCli {
    if (!this.client) {
      this.resolveCli();
    }
    if (!this.client) {
      throw this.cliError instanceof CliNotFoundError ? this.cliError : new CliNotFoundError();
    }
    return this.client;
  }

  // MARK: Indexing

  /** Indexes one folder; failures are logged and reflected in the status bar, then rethrown. */
  async index(repository: Repository, options: { rebuild?: boolean; token?: vscode.CancellationToken } = {}): Promise<IndexSummary> {
    try {
      const summary = await repository.index(options);
      this.log.appendLine(
        `Indexed ${repository.folder.name}: ${summary.filesScanned} files (${summary.filesAdded} added, ${summary.filesChanged} changed, ${summary.filesRemoved} removed) in ${summary.durationSeconds.toFixed(2)} s`,
      );
      summary.warnings.forEach((warning) => this.log.appendLine(`  warning: ${warning}`));
      return summary;
    } catch (error) {
      if (error instanceof CliNotFoundError) {
        this.statusBar.setCliMissing(true);
      } else if (!(error instanceof vscode.CancellationError)) {
        this.log.appendLine(`Index update failed for ${repository.folder.name}: ${errorMessage(error)}`);
        this.statusBar.setFailure(errorMessage(error));
      }
      throw error;
    }
  }

  private indexAll(): Promise<void> {
    if (!this.client) {
      void this.promptForCli();
      return Promise.resolve();
    }
    const runs = this.repositories.all.map((repository) => this.index(repository).catch(() => undefined));
    return Promise.all(runs).then(() => this.settle());
  }

  /** Resolves when the view refreshes triggered by index updates have finished. */
  async settle(): Promise<void> {
    await Promise.all([...this.refreshes.values()]);
  }

  private scheduleIndex(uri: vscode.Uri): void {
    const repository = this.repositories.for(uri);
    if (!repository || repository.relativePath(uri) === undefined || !this.client) {
      return;
    }
    if (!vscode.workspace.getConfiguration('vesalius', repository.folder.uri).get<boolean>('indexOnSave', true)) {
      return;
    }
    clearTimeout(this.saveTimers.get(repository));
    this.saveTimers.set(
      repository,
      setTimeout(() => {
        this.saveTimers.delete(repository);
        this.index(repository).catch(() => undefined);
      }, saveDebounceMs),
    );
  }

  // MARK: Refresh

  private wire(repository: Repository): void {
    if (this.wired.has(repository)) {
      return;
    }
    this.wired.add(repository);
    repository.onDidUpdate(() => {
      const refresh = this.afterUpdate(repository);
      this.refreshes.set(repository, refresh);
      void refresh.finally(() => {
        if (this.refreshes.get(repository) === refresh) {
          this.refreshes.delete(repository);
        }
      });
    });
    repository.onDidChangeIndexing(() => this.statusBar.setIndexing(this.repositories.all.some((r) => r.isIndexing)));
  }

  private async afterUpdate(repository: Repository): Promise<void> {
    const tasks: Promise<unknown>[] = [this.diagnostics.refresh(repository)];
    if (repository === this.repositories.active) {
      tasks.push(this.refreshHealth());
      this.hotspots.invalidate();
    }
    const shown = this.currentFile.uri;
    if (!shown || this.repositories.for(shown) === repository) {
      tasks.push(this.currentFile.refresh());
    }
    this.codeLens.refresh();
    await Promise.all(tasks);
  }

  /** Reloads the Health view and the status bar from the active folder's index. */
  async refreshHealth(): Promise<void> {
    await this.health.refresh();
    const result = this.health.current;
    this.statusBar.setHealth(result);
    const urgent = (result?.health.diagnosticCounts.critical ?? 0) + (result?.health.diagnosticCounts.high ?? 0);
    this.healthView.badge = urgent > 0 ? { value: urgent, tooltip: `${urgent} high-severity ${urgent === 1 ? 'finding' : 'findings'}` } : undefined;
  }

  private onActiveEditorChanged(): void {
    const editor = vscode.window.activeTextEditor;
    const visible = vscode.window.visibleTextEditors;
    if (editor && editor.document.uri.scheme === 'file') {
      this.follow(editor.document.uri);
    } else if (!editor && visible.length === 0) {
      this.follow(undefined);
    } else if (!editor && this.lastFileEditor) {
      // Focus moved to a panel, webview or view. Keep following the last file editor, including one
      // that was active too briefly for the debounce (for example, just before a panel opened).
      const last = this.lastFileEditor;
      if (last.toString() !== this.followedFile?.toString() && visible.some((e) => e.document.uri.toString() === last.toString())) {
        this.follow(last);
      }
    }
    const active = this.repositories.active;
    if (active !== this.activeRepository) {
      this.activeRepository = active;
      void this.refreshHealth();
      this.hotspots.invalidate();
    }
  }

  /** Shows `uri` in the Current File view unless it is already loaded there. */
  private follow(uri: vscode.Uri | undefined): void {
    this.followedFile = uri;
    if (!uri || uri.toString() !== this.currentFile.uri?.toString() || !this.currentFile.fileContext) {
      void this.currentFile.load(uri);
    }
  }

  private onFoldersChanged(): void {
    const added = this.repositories.all.filter((repository) => !this.wired.has(repository));
    added.forEach((repository) => this.wire(repository));
    for (const repository of [...this.wired]) {
      if (!this.repositories.all.includes(repository)) {
        this.wired.delete(repository);
        this.refreshes.delete(repository);
      }
    }
    this.mcp.refresh();
    this.statusBar.setHealth(this.health.current);
    if (this.client && added.length > 0) {
      this.ready = Promise.all(added.map((repository) => this.index(repository).catch(() => undefined))).then(() => this.settle());
    }
    this.onActiveEditorChanged();
  }

  private onConfigurationChanged(event: vscode.ConfigurationChangeEvent): void {
    if (event.affectsConfiguration('vesalius.cliPath')) {
      const before = this.location?.command;
      this.resolveCli();
      if (this.client && this.location?.command !== before) {
        this.ready = this.indexAll();
      }
    }
    if (event.affectsConfiguration('vesalius.diagnostics')) {
      void this.diagnostics.refreshAll();
    }
    if (event.affectsConfiguration('vesalius.codeLens')) {
      this.codeLens.refresh();
    }
  }

  // MARK: App and installation

  /** Opens the Vesalius app on a repository via its `vesalius://open` deep link, else `open -a Vesalius`. */
  async openInApp(repository: Repository, options: Record<string, string | undefined> = {}): Promise<void> {
    if (process.platform !== 'darwin') {
      void vscode.window.showInformationMessage('The Vesalius app runs on macOS. On this system, use the views in the Vesalius sidebar.');
      return;
    }
    const query = Object.entries({ repo: repository.root, ...options })
      .filter((entry): entry is [string, string] => typeof entry[1] === 'string' && entry[1].length > 0)
      .map(([key, value]) => `${key}=${encodeURIComponent(value)}`)
      .join('&');
    const link = `vesalius://open?${query}`;
    this.log.appendLine(`open ${link}`);
    if (await run('open', [link])) {
      return;
    }
    if (await run('open', ['-a', 'Vesalius', repository.root])) {
      return;
    }
    void vscode.window.showWarningMessage('Vesalius.app was not found on this Mac. Install the app, then try again.');
  }

  /** Links ~/.local/bin/vesalius to the app's built-in command line tool (no administrator rights). */
  async installCli(): Promise<void> {
    const app = process.platform === 'darwin' ? findAppBinary() : undefined;
    if (!app) {
      const choice = await vscode.window.showWarningMessage(
        'The Vesalius app was not found.',
        {
          modal: true,
          detail:
            'Install Vesalius.app (it includes the command line tool), or build the CLI from source with "swift build -c release --product vesalius" in VesaliusKit and set "vesalius.cliPath" to the built binary.',
        },
        'Set CLI Path…',
      );
      if (choice) {
        await vscode.commands.executeCommand('workbench.action.openSettings', 'vesalius.cliPath');
      }
      return;
    }
    const link = path.join(os.homedir(), '.local', 'bin', 'vesalius');
    const display = link.replace(os.homedir(), '~');
    const choice = await vscode.window.showInformationMessage(
      'Install the vesalius command?',
      { modal: true, detail: `Creates ${display}, a link to the command line tool inside ${app.replace(/\/Contents\/MacOS\/Vesalius$/, '')}. No administrator password is needed.` },
      'Install',
    );
    if (choice !== 'Install') {
      return;
    }
    try {
      fs.mkdirSync(path.dirname(link), { recursive: true });
      const existing = fs.lstatSync(link, { throwIfNoEntry: false });
      if (existing) {
        if (!existing.isSymbolicLink()) {
          throw new Error(`${display} already exists and is not a link. Remove it, or set "vesalius.cliPath" instead.`);
        }
        fs.unlinkSync(link);
      }
      fs.symlinkSync(app, link);
    } catch (error) {
      void vscode.window.showErrorMessage(`Vesalius: ${errorMessage(error)}`);
      return;
    }
    if (this.resolveCli()) {
      void vscode.window.showInformationMessage(`Installed ${display}. Vesalius is indexing this workspace.`);
      this.ready = this.indexAll();
    }
  }

  private async promptForCli(): Promise<void> {
    if (this.cliPrompted || !vscode.workspace.workspaceFolders?.length || this.context.globalState.get<boolean>('vesalius.hideCliPrompt')) {
      return;
    }
    this.cliPrompted = true;
    const configured = this.cliError instanceof CliNotFoundError && this.cliError.configuredPath;
    const message = configured ? this.cliError?.message ?? '' : 'Vesalius needs its command line tool to index this workspace.';
    const choice = await vscode.window.showInformationMessage(message, 'Install', 'Set Path…', "Don't Show Again");
    if (choice === 'Install') {
      await this.installCli();
    } else if (choice === 'Set Path…') {
      await vscode.commands.executeCommand('workbench.action.openSettings', 'vesalius.cliPath');
    } else if (choice === "Don't Show Again") {
      await this.context.globalState.update('vesalius.hideCliPrompt', true);
    }
  }

  /** User-facing presentation of a failure; quiet for cancellations. */
  async showError(error: unknown): Promise<void> {
    if (error instanceof vscode.CancellationError) {
      return;
    }
    if (error instanceof CliNotFoundError) {
      const choice = await vscode.window.showWarningMessage(error.message, 'Install', 'Set Path…');
      if (choice === 'Install') {
        await this.installCli();
      } else if (choice === 'Set Path…') {
        await vscode.commands.executeCommand('workbench.action.openSettings', 'vesalius.cliPath');
      }
      return;
    }
    if (error instanceof CliError && error.isNotFound) {
      void vscode.window.showInformationMessage(error.message);
      return;
    }
    this.log.appendLine(`Error: ${errorMessage(error)}`);
    const choice = await vscode.window.showErrorMessage(`Vesalius: ${errorMessage(error)}`, 'Show Log');
    if (choice) {
      this.log.show(true);
    }
  }
}

function run(command: string, args: string[]): Promise<boolean> {
  return new Promise((resolve) => execFile(command, args, { timeout: 15000 }, (error) => resolve(!error)));
}
