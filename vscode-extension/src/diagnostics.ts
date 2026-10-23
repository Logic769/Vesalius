import * as vscode from 'vscode';
import { CliNotFoundError } from './cli';
import { Repositories, Repository } from './repository';
import { Diagnostic, DiagnosticTarget, Severity, severityOrder } from './types';
import { errorMessage, LineReader, splitPath } from './util';

/** critical and high → Warning, medium → Information, low and info → Hint. */
export function vscodeSeverity(severity: Severity): vscode.DiagnosticSeverity {
  switch (severity) {
    case 'critical':
    case 'high':
      return vscode.DiagnosticSeverity.Warning;
    case 'medium':
      return vscode.DiagnosticSeverity.Information;
    default:
      return vscode.DiagnosticSeverity.Hint;
  }
}

/**
 * Publishes Vesalius findings to the Problems panel: one entry per affected file, or per symbol line
 * when a finding names specific declarations.
 */
export class DiagnosticsController implements vscode.Disposable {
  readonly collection = vscode.languages.createDiagnosticCollection('vesalius');
  private readonly versions = new Map<string, number>();

  constructor(
    private readonly repositories: Repositories,
    private readonly log: vscode.OutputChannel,
  ) {}

  dispose(): void {
    this.collection.dispose();
  }

  refreshAll(): Promise<void> {
    return Promise.all(this.repositories.all.map((repository) => this.refresh(repository))).then(() => undefined);
  }

  async refresh(repository: Repository): Promise<void> {
    const key = repository.folder.uri.toString();
    const version = (this.versions.get(key) ?? 0) + 1;
    this.versions.set(key, version);

    const config = vscode.workspace.getConfiguration('vesalius', repository.folder.uri);
    if (!config.get<boolean>('diagnostics.enabled', true)) {
      this.clear(repository);
      return;
    }
    const configured = config.get<Severity>('diagnostics.minimumSeverity', 'medium');
    const minimum = severityOrder.includes(configured) ? configured : 'medium';

    let findings: Diagnostic[];
    try {
      findings = await repository.diagnostics(minimum);
    } catch (error) {
      if (!(error instanceof CliNotFoundError)) {
        this.log.appendLine(`Problems not updated: ${errorMessage(error)}`);
      }
      return;
    }
    if (this.versions.get(key) !== version) {
      return; // A newer refresh superseded this one.
    }

    const reader = new LineReader();
    const byFile = new Map<string, { uri: vscode.Uri; diagnostics: vscode.Diagnostic[] }>();
    for (const finding of findings) {
      for (const { uri, line } of placements(finding, repository)) {
        const entry = byFile.get(uri.toString()) ?? { uri, diagnostics: [] };
        entry.diagnostics.push(this.convert(finding, uri, line, repository, reader));
        byFile.set(uri.toString(), entry);
      }
    }
    this.clear(repository);
    this.collection.set([...byFile.values()].map(({ uri, diagnostics }) => [uri, diagnostics] as [vscode.Uri, vscode.Diagnostic[]]));
  }

  private convert(finding: Diagnostic, uri: vscode.Uri, line: number | undefined, repository: Repository, reader: LineReader): vscode.Diagnostic {
    const range = reader.lineRange(uri, line);
    const diagnostic = new vscode.Diagnostic(range, finding.title, vscodeSeverity(finding.severity));
    diagnostic.source = 'Vesalius';
    diagnostic.code = finding.rule;
    const here = new vscode.Location(uri, range);
    const related = [new vscode.DiagnosticRelatedInformation(here, `Suggestion: ${finding.recommendation}`)];
    if (finding.summary && finding.summary !== finding.title) {
      related.push(new vscode.DiagnosticRelatedInformation(here, finding.summary));
    }
    const others = new Set<string>();
    for (const target of finding.targets) {
      const otherUri = targetUri(target, repository);
      if (otherUri && otherUri.toString() !== uri.toString() && !others.has(target.path)) {
        others.add(target.path);
        related.push(new vscode.DiagnosticRelatedInformation(new vscode.Location(otherUri, reader.lineRange(otherUri, target.line)), `Also involved: ${splitPath(target.path).name}`));
      }
    }
    diagnostic.relatedInformation = related;
    return diagnostic;
  }

  private clear(repository: Repository): void {
    const stale: vscode.Uri[] = [];
    this.collection.forEach((uri) => {
      if (repository.relativePath(uri) !== undefined) {
        stale.push(uri);
      }
    });
    stale.forEach((uri) => this.collection.delete(uri));
  }
}

function targetUri(target: DiagnosticTarget, repository: Repository): vscode.Uri | undefined {
  return target.kind === 'file' || target.kind === 'symbol' ? repository.uri(target.path) : undefined;
}

/** Where a finding appears: each symbol line it names, else line 1 of each file it names. */
function placements(finding: Diagnostic, repository: Repository): { uri: vscode.Uri; line: number | undefined }[] {
  const byPath = new Map<string, DiagnosticTarget[]>();
  for (const target of finding.targets) {
    if (target.kind === 'file' || target.kind === 'symbol') {
      byPath.set(target.path, [...(byPath.get(target.path) ?? []), target]);
    }
  }
  const result: { uri: vscode.Uri; line: number | undefined }[] = [];
  for (const [path, targets] of byPath) {
    const uri = repository.uri(path);
    const lines = [...new Set(targets.map((target) => target.line).filter((line): line is number => typeof line === 'number' && line > 0))];
    if (lines.length === 0) {
      result.push({ uri, line: undefined });
    } else {
      lines.forEach((line) => result.push({ uri, line }));
    }
  }
  return result;
}
