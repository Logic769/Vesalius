import * as vscode from 'vscode';
import { Repositories } from './repository';
import { FileContext, parseLines, SymbolKind } from './types';
import { findIdentifier, plural } from './util';

/** Declarations that get a lens: top-level types and functions. */
const lensKinds = new Set<SymbolKind>(['class', 'struct', 'enum', 'protocol', 'interface', 'actor', 'typealias', 'function', 'component']);

/** "N references · risk <level>" above top-level types and functions; click peeks the references. */
export class VesaliusCodeLensProvider implements vscode.CodeLensProvider {
  private readonly changed = new vscode.EventEmitter<void>();
  readonly onDidChangeCodeLenses = this.changed.event;

  constructor(private readonly repositories: Repositories) {}

  refresh(): void {
    this.changed.fire();
  }

  async provideCodeLenses(document: vscode.TextDocument, token: vscode.CancellationToken): Promise<vscode.CodeLens[]> {
    if (!vscode.workspace.getConfiguration('vesalius', document.uri).get<boolean>('codeLens.enabled', true)) {
      return [];
    }
    const repository = this.repositories.for(document.uri);
    const relativePath = repository?.relativePath(document.uri);
    if (!repository || !relativePath) {
      return [];
    }
    let context: FileContext | undefined;
    try {
      context = await repository.fileContext(relativePath);
    } catch {
      return [];
    }
    if (!context || token.isCancellationRequested) {
      return [];
    }
    const { riskLevel, riskScore } = context.impact;
    const lenses: vscode.CodeLens[] = [];
    for (const symbol of context.symbols) {
      const lines = parseLines(symbol.lines);
      if ((symbol.depth ?? 0) !== 0 || !lensKinds.has(symbol.kind) || !lines || lines.start > document.lineCount) {
        continue;
      }
      const line = document.lineAt(lines.start - 1);
      const column = findIdentifier(line.text, symbol.name);
      const position = new vscode.Position(line.lineNumber, Math.max(0, column >= 0 ? column : line.firstNonWhitespaceCharacterIndex));
      const references = symbol.references ?? 0;
      lenses.push(
        new vscode.CodeLens(line.range, {
          title: `${plural(references, 'reference')} · risk ${riskLevel}`,
          tooltip: `${symbol.qualifiedName}: ${plural(references, 'reference')} in the index. Changing ${context.file.path} carries ${riskLevel} risk (${Math.round(riskScore)}/100). Click to peek the references.`,
          command: 'vesalius.showReferencesAt',
          arguments: [document.uri, position, symbol.id, symbol.name],
        }),
      );
    }
    return lenses;
  }
}
