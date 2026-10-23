import * as fs from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import { RiskLevel, Severity, SymbolKind } from './types';

/** Opens a file with the cursor on a 1-based line range (or at the top of the file) and reveals it. */
export async function openLocation(uri: vscode.Uri, startLine?: number, endLine?: number, viewColumn?: vscode.ViewColumn): Promise<vscode.TextEditor> {
  const document = await vscode.workspace.openTextDocument(uri);
  let selection: vscode.Range | undefined;
  let reveal: vscode.Range | undefined;
  if (startLine && startLine > 0 && document.lineCount > 0) {
    const first = Math.min(startLine - 1, document.lineCount - 1);
    const last = Math.max(first, Math.min((endLine ?? startLine) - 1, document.lineCount - 1));
    const cursor = new vscode.Position(first, document.lineAt(first).firstNonWhitespaceCharacterIndex);
    selection = new vscode.Range(cursor, cursor);
    reveal = new vscode.Range(first, 0, last, document.lineAt(last).text.length);
  }
  // Passing the selection with the show request applies it atomically, without a jump.
  const editor = await vscode.window.showTextDocument(document, { preview: true, viewColumn, selection });
  if (reveal) {
    editor.revealRange(reveal, vscode.TextEditorRevealType.InCenterIfOutsideViewport);
  }
  return editor;
}

export function severityIcon(severity: Severity): vscode.ThemeIcon {
  switch (severity) {
    case 'critical':
      return new vscode.ThemeIcon('error', new vscode.ThemeColor('list.errorForeground'));
    case 'high':
      return new vscode.ThemeIcon('warning', new vscode.ThemeColor('list.warningForeground'));
    case 'medium':
      return new vscode.ThemeIcon('info', new vscode.ThemeColor('editorInfo.foreground'));
    default:
      return new vscode.ThemeIcon('circle-small');
  }
}

export function riskIcon(level: RiskLevel): vscode.ThemeIcon {
  switch (level) {
    case 'critical':
      return new vscode.ThemeIcon('flame', new vscode.ThemeColor('list.errorForeground'));
    case 'high':
      return new vscode.ThemeIcon('flame', new vscode.ThemeColor('list.warningForeground'));
    case 'moderate':
      return new vscode.ThemeIcon('shield', new vscode.ThemeColor('editorInfo.foreground'));
    default:
      return new vscode.ThemeIcon('shield');
  }
}

export function symbolIcon(kind: SymbolKind): vscode.ThemeIcon {
  const map: Partial<Record<SymbolKind, string>> = {
    class: 'symbol-class',
    struct: 'symbol-struct',
    enum: 'symbol-enum',
    protocol: 'symbol-interface',
    interface: 'symbol-interface',
    actor: 'symbol-class',
    extension: 'symbol-namespace',
    typealias: 'symbol-type-parameter',
    function: 'symbol-function',
    method: 'symbol-method',
    initializer: 'symbol-constructor',
    property: 'symbol-property',
    variable: 'symbol-variable',
    constant: 'symbol-constant',
    case: 'symbol-enum-member',
    namespace: 'symbol-namespace',
    macro: 'symbol-misc',
    component: 'symbol-class',
  };
  return new vscode.ThemeIcon(map[kind] ?? 'symbol-misc');
}

/** "src/api/users.ts" → { name: "users.ts", directory: "src/api" }. */
export function splitPath(relativePath: string): { name: string; directory: string } {
  return { name: path.posix.basename(relativePath), directory: path.posix.dirname(relativePath) === '.' ? '' : path.posix.dirname(relativePath) };
}

export function plural(count: number, noun: string, pluralNoun = `${noun}s`): string {
  return `${count} ${count === 1 ? noun : pluralNoun}`;
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** The identifier under the cursor (or the selection), including dotted member access. */
export function wordAtCursor(editor: vscode.TextEditor | undefined): string | undefined {
  if (!editor) {
    return undefined;
  }
  const selection = editor.document.getText(editor.selection).trim();
  if (selection && /^[\w.$]+$/.test(selection)) {
    return selection;
  }
  const range = editor.document.getWordRangeAtPosition(editor.selection.active, /[A-Za-z_$][\w$]*/);
  return range ? editor.document.getText(range) : undefined;
}

/**
 * Reads lines of workspace files, preferring the open (possibly unsaved) document over the disk copy.
 * One instance caches files for the duration of a single operation.
 */
export class LineReader {
  private readonly files = new Map<string, string[]>();

  lines(uri: vscode.Uri): string[] {
    const key = uri.toString();
    let lines = this.files.get(key);
    if (!lines) {
      const open = vscode.workspace.textDocuments.find((document) => document.uri.toString() === key);
      let text = '';
      if (open) {
        text = open.getText();
      } else {
        try {
          text = fs.readFileSync(uri.fsPath, 'utf8');
        } catch {
          text = '';
        }
      }
      lines = text.split(/\r?\n/);
      this.files.set(key, lines);
    }
    return lines;
  }

  /** Range covering the text of a 1-based line (trimmed of indentation), clamped to the file. */
  lineRange(uri: vscode.Uri, line: number | undefined): vscode.Range {
    const lines = this.lines(uri);
    const index = Math.max(0, Math.min((line ?? 1) - 1, lines.length - 1));
    const text = lines[index] ?? '';
    const start = Math.max(0, text.search(/\S/));
    return new vscode.Range(index, start, index, Math.max(start, text.trimEnd().length));
  }

  /** Range of `name` on a 1-based line (first whole-word match), or the line's text when it is absent. */
  nameRange(uri: vscode.Uri, line: number, name: string): vscode.Range {
    const lines = this.lines(uri);
    const index = Math.max(0, Math.min(line - 1, lines.length - 1));
    const column = findIdentifier(lines[index] ?? '', name);
    return column >= 0 ? new vscode.Range(index, column, index, column + identifierTail(name).length) : this.lineRange(uri, line);
  }
}

/**
 * A readable name for a stable symbol id: "sym:Sources/App/Store.swift#Store.save~2" → "Store.save".
 * Ids of later overloads end in ~2, ~3; plain names pass through unchanged.
 */
export function symbolLabel(idOrName: string): string {
  const name = idOrName.startsWith('sym:') && idOrName.includes('#') ? idOrName.slice(idOrName.lastIndexOf('#') + 1) : idOrName;
  return name.replace(/~\d+$/, '');
}

/** "Type.member" → "member": the part of a qualified name that appears at use sites. */
export function identifierTail(name: string): string {
  return name.slice(name.lastIndexOf('.') + 1);
}

/** Column of the first whole-word occurrence of `name` (or its last dotted component), or -1. */
export function findIdentifier(text: string, name: string): number {
  const tail = identifierTail(name);
  if (!tail) {
    return -1;
  }
  const escaped = tail.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = new RegExp(`(^|[^\\w$])(${escaped})(?![\\w$])`).exec(text);
  return match ? match.index + match[1].length : -1;
}
