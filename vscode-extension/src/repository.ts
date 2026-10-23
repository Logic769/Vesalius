import * as path from 'path';
import * as vscode from 'vscode';
import { CliError, VesaliusCli } from './cli';
import { AskResult, CallGraphResult, Diagnostic, FileContext, HealthResult, Hotspot, ImpactReport, IndexSummary, ReferencesResult, Severity } from './types';

/**
 * One workspace folder backed by a Vesalius index. Index updates are serialised; queries run
 * concurrently against the existing index (`--no-refresh`) and index first when there is none yet.
 */
export class Repository implements vscode.Disposable {
  private readonly updated = new vscode.EventEmitter<IndexSummary | undefined>();
  private readonly indexingChanged = new vscode.EventEmitter<boolean>();
  /** Fires after the index changed (views, diagnostics and lenses refresh). */
  readonly onDidUpdate = this.updated.event;
  readonly onDidChangeIndexing = this.indexingChanged.event;

  private queue: Promise<unknown> = Promise.resolve();
  private activeIndexRuns = 0;
  private contextCache = new Map<string, Promise<FileContext | undefined>>();
  generation = 0;
  lastSummary: IndexSummary | undefined;

  constructor(
    readonly folder: vscode.WorkspaceFolder,
    private readonly cli: () => VesaliusCli,
  ) {}

  dispose(): void {
    this.updated.dispose();
    this.indexingChanged.dispose();
  }

  get root(): string {
    return this.folder.uri.fsPath;
  }

  get isIndexing(): boolean {
    return this.activeIndexRuns > 0;
  }

  /** Repository-relative path of a document in this folder, or undefined when it lives elsewhere. */
  relativePath(uri: vscode.Uri): string | undefined {
    if (uri.scheme !== 'file') {
      return undefined;
    }
    const relative = path.relative(this.root, uri.fsPath);
    if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) {
      return undefined;
    }
    return relative.split(path.sep).join('/');
  }

  uri(relativePath: string): vscode.Uri {
    return vscode.Uri.joinPath(this.folder.uri, ...relativePath.split('/'));
  }

  private config(): vscode.WorkspaceConfiguration {
    return vscode.workspace.getConfiguration('vesalius', this.folder.uri);
  }

  // MARK: Index

  /** Builds or incrementally updates the index. Concurrent requests run one after another. */
  index(options: { rebuild?: boolean; token?: vscode.CancellationToken } = {}): Promise<IndexSummary> {
    const run = async (): Promise<IndexSummary> => {
      this.activeIndexRuns += 1;
      if (this.activeIndexRuns === 1) {
        this.indexingChanged.fire(true);
      }
      try {
        const args = ['index', this.root, '--json', '-q'];
        if (options.rebuild) {
          args.push('--rebuild');
        }
        const timeoutMs = (this.config().get<number>('indexTimeoutSeconds') ?? 900) * 1000;
        const summary = await this.cli().run<IndexSummary>(args, { cwd: this.root, timeoutMs, token: options.token });
        this.lastSummary = summary;
        const changed = options.rebuild || this.generation === 0 || summary.filesAdded + summary.filesChanged + summary.filesRemoved > 0 || summary.analysisUpdated === true;
        if (changed) {
          this.generation += 1;
          this.contextCache.clear();
          this.updated.fire(summary);
        }
        return summary;
      } finally {
        this.activeIndexRuns -= 1;
        if (this.activeIndexRuns === 0) {
          this.indexingChanged.fire(false);
        }
      }
    };
    const next = this.queue.then(run, run);
    this.queue = next.catch(() => undefined);
    return next;
  }

  // MARK: Queries

  /** Runs a query against the index (`--json --no-refresh`), indexing first if needed. */
  async query<T>(args: string[], token?: vscode.CancellationToken): Promise<T> {
    const fullArgs = [...args, '--json', '--repo', this.root, '--no-refresh'];
    const timeoutMs = (this.config().get<number>('queryTimeoutSeconds') ?? 60) * 1000;
    try {
      return await this.cli().run<T>(fullArgs, { cwd: this.root, timeoutMs, token });
    } catch (error) {
      if (error instanceof CliError && error.isNotIndexed) {
        await this.index({ token });
        return this.cli().run<T>(fullArgs, { cwd: this.root, timeoutMs, token });
      }
      throw error;
    }
  }

  ask(question: string, limit = 12, token?: vscode.CancellationToken): Promise<AskResult> {
    return this.query<AskResult>(['ask', question, '--limit', String(limit)], token);
  }

  /** File context, cached per index generation (shared by the tree, CodeLens and commands). */
  fileContext(relativePath: string): Promise<FileContext | undefined> {
    const key = `${this.generation}:${relativePath}`;
    let pending = this.contextCache.get(key);
    if (!pending) {
      pending = this.query<FileContext>(['context', relativePath]).catch((error: unknown) => {
        this.contextCache.delete(key);
        if (error instanceof CliError && error.isNotFound) {
          return undefined;
        }
        throw error;
      });
      this.contextCache.set(key, pending);
    }
    return pending;
  }

  impact(target: string, token?: vscode.CancellationToken): Promise<ImpactReport> {
    return this.query<ImpactReport>(['impact', target, '--depth', '6'], token);
  }

  references(symbol: string, token?: vscode.CancellationToken): Promise<ReferencesResult> {
    return this.query<ReferencesResult>(['references', symbol, '--limit', '200'], token);
  }

  callers(symbol: string, token?: vscode.CancellationToken): Promise<CallGraphResult> {
    return this.query<CallGraphResult>(['callers', symbol, '--limit', '200'], token);
  }

  health(token?: vscode.CancellationToken): Promise<HealthResult> {
    return this.query<HealthResult>(['health', '--limit', '60'], token);
  }

  diagnostics(minimum: Severity, token?: vscode.CancellationToken): Promise<Diagnostic[]> {
    return this.query<Diagnostic[]>(['diagnostics', '--severity', minimum, '--limit', '1000'], token);
  }

  hotspots(token?: vscode.CancellationToken): Promise<Hotspot[]> {
    return this.query<Hotspot[]>(['hotspots', '--limit', '25'], token);
  }
}

/** Repositories for every workspace folder; the active one follows the active editor. */
export class Repositories implements vscode.Disposable {
  private readonly byFolder = new Map<string, Repository>();
  private readonly changed = new vscode.EventEmitter<void>();
  readonly onDidChange = this.changed.event;
  private readonly disposables: vscode.Disposable[] = [];

  constructor(private readonly cli: () => VesaliusCli) {
    this.sync();
    this.disposables.push(vscode.workspace.onDidChangeWorkspaceFolders(() => this.sync()));
  }

  dispose(): void {
    for (const repository of this.byFolder.values()) {
      repository.dispose();
    }
    this.disposables.forEach((d) => d.dispose());
    this.changed.dispose();
  }

  private sync(): void {
    const folders = vscode.workspace.workspaceFolders ?? [];
    const keys = new Set(folders.map((folder) => folder.uri.toString()));
    for (const [key, repository] of this.byFolder) {
      if (!keys.has(key)) {
        repository.dispose();
        this.byFolder.delete(key);
      }
    }
    for (const folder of folders) {
      const key = folder.uri.toString();
      if (!this.byFolder.has(key)) {
        this.byFolder.set(key, new Repository(folder, this.cli));
      }
    }
    this.changed.fire();
  }

  get all(): Repository[] {
    return [...this.byFolder.values()];
  }

  for(uri: vscode.Uri | undefined): Repository | undefined {
    if (!uri) {
      return undefined;
    }
    const folder = vscode.workspace.getWorkspaceFolder(uri);
    return folder ? this.byFolder.get(folder.uri.toString()) : undefined;
  }

  /** The repository of the active editor, else the first folder. */
  get active(): Repository | undefined {
    return this.for(vscode.window.activeTextEditor?.document.uri) ?? this.all[0];
  }
}
