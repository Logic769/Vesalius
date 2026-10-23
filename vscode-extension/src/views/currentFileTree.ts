import * as vscode from 'vscode';
import { CliNotFoundError } from '../cli';
import { Repositories, Repository } from '../repository';
import { Diagnostic, FileContext, FileRelation, parseLines, RelatedFile, SymbolSummary } from '../types';
import { errorMessage, plural, riskIcon, severityIcon, splitPath, symbolIcon } from '../util';

type Group = 'findings' | 'dependents' | 'dependencies' | 'symbols' | 'related';

export type CurrentFileNode =
  | { type: 'overview'; context: FileContext; repository: Repository }
  | { type: 'group'; group: Group; context: FileContext; repository: Repository }
  | { type: 'symbol'; symbol: SymbolSummary; members: SymbolSummary[]; repository: Repository }
  | { type: 'relation'; relation: FileRelation; direction: 'dependent' | 'dependency'; repository: Repository }
  | { type: 'related'; related: RelatedFile; repository: Repository }
  | { type: 'diagnostic'; diagnostic: Diagnostic; path: string; repository: Repository }
  | { type: 'message'; text: string; detail?: string; command?: vscode.Command };

const groupTitles: Record<Group, string> = {
  findings: 'Findings',
  dependents: 'Used by',
  dependencies: 'Depends on',
  symbols: 'Symbols',
  related: 'Related',
};

/** What the active file contains, what it uses, what uses it, and how risky it is to change. */
export class CurrentFileTreeProvider implements vscode.TreeDataProvider<CurrentFileNode> {
  private readonly changed = new vscode.EventEmitter<CurrentFileNode | undefined>();
  readonly onDidChangeTreeData = this.changed.event;
  view: vscode.TreeView<CurrentFileNode> | undefined;

  private target: { uri: vscode.Uri; repository: Repository; relativePath: string } | undefined;
  private context: FileContext | undefined;
  private error: string | undefined;
  private loadID = 0;

  constructor(private readonly repositories: Repositories) {}

  /** The file shown in the view. */
  get uri(): vscode.Uri | undefined {
    return this.target?.uri;
  }

  get fileContext(): FileContext | undefined {
    return this.context;
  }

  /** Shows `uri` (default: the active editor's file) and resolves once its context is loaded. */
  async load(uri: vscode.Uri | undefined = vscode.window.activeTextEditor?.document.uri): Promise<void> {
    const id = ++this.loadID;
    const repository = this.repositories.for(uri);
    const relativePath = uri ? repository?.relativePath(uri) : undefined;
    if (!uri || !repository || !relativePath) {
      this.target = undefined;
      this.context = undefined;
      this.error = undefined;
      this.present(uri ? 'This file is outside the workspace folders Vesalius indexes.' : 'Open a file to see what it uses, what depends on it and how risky it is to change.');
      return;
    }
    this.target = { uri, repository, relativePath };
    try {
      const context = await repository.fileContext(relativePath);
      if (id !== this.loadID) {
        return;
      }
      this.context = context;
      this.error = undefined;
      this.present(context ? undefined : `${splitPath(relativePath).name} is not in the index. It may be ignored, generated, or a language Vesalius does not read.`);
    } catch (error) {
      if (id !== this.loadID) {
        return;
      }
      this.context = undefined;
      this.error = error instanceof CliNotFoundError ? undefined : errorMessage(error);
      this.present(error instanceof CliNotFoundError ? error.message : undefined);
    }
  }

  /** Reloads the shown file (after the index changed). */
  refresh(): Promise<void> {
    return this.load(this.target?.uri ?? vscode.window.activeTextEditor?.document.uri);
  }

  private present(message: string | undefined): void {
    if (this.view) {
      this.view.message = message;
      this.view.description = this.target ? splitPath(this.target.relativePath).name : undefined;
    }
    this.changed.fire(undefined);
  }

  getTreeItem(node: CurrentFileNode): vscode.TreeItem {
    switch (node.type) {
      case 'overview': {
        const { impact, file, metrics } = node.context;
        const level = impact.riskLevel[0].toUpperCase() + impact.riskLevel.slice(1);
        const item = new vscode.TreeItem(`${level} change risk`, vscode.TreeItemCollapsibleState.None);
        item.description = `${Math.round(impact.riskScore)}/100 · ${impact.relatedTests === 0 ? 'no tests' : plural(impact.relatedTests, 'test')}`;
        item.iconPath = riskIcon(impact.riskLevel);
        const tooltip = new vscode.MarkdownString(undefined, true);
        tooltip.appendMarkdown(`**${file.path}**\n\n`);
        tooltip.appendMarkdown(`| | |\n|---|---|\n`);
        tooltip.appendMarkdown(`| Language | ${file.language} |\n| Lines of code | ${file.codeLines} |\n| Complexity | ${file.complexity} |\n`);
        tooltip.appendMarkdown(`| Fan-in / fan-out | ${metrics.fanIn} / ${metrics.fanOut} |\n| Direct dependents | ${impact.directDependents} |\n| Transitive dependents | ${impact.transitiveDependents} |\n| Related tests | ${impact.relatedTests} |\n`);
        if (metrics.cycleSize) {
          tooltip.appendMarkdown(`| Dependency cycle | ${metrics.cycleSize} files |\n`);
        }
        tooltip.appendMarkdown(`\nClick to see the full blast radius.`);
        item.tooltip = tooltip;
        item.command = { command: 'vesalius.showImpact', title: 'Show Change Impact', arguments: [node.repository.uri(file.path)] };
        return item;
      }
      case 'group': {
        const children = this.groupChildren(node);
        const expanded = node.group === 'dependents' || node.group === 'findings' || (node.group === 'dependencies' && children.length <= 6);
        const item = new vscode.TreeItem(groupTitles[node.group], children.length === 0 ? vscode.TreeItemCollapsibleState.None : expanded ? vscode.TreeItemCollapsibleState.Expanded : vscode.TreeItemCollapsibleState.Collapsed);
        item.id = `group:${node.group}`;
        item.description = children.length === 0 && node.group === 'dependents' ? 'nothing in the index uses this file' : `${children.length}`;
        item.iconPath = new vscode.ThemeIcon(
          { findings: 'lightbulb', dependents: 'arrow-left', dependencies: 'arrow-right', symbols: 'symbol-namespace', related: 'git-compare' }[node.group],
        );
        return item;
      }
      case 'symbol': {
        const { symbol } = node;
        const item = new vscode.TreeItem(symbol.name, node.members.length > 0 ? vscode.TreeItemCollapsibleState.Collapsed : vscode.TreeItemCollapsibleState.None);
        const references = symbol.references ?? 0;
        item.description = `${symbol.kind}${references > 0 ? ` · ${plural(references, 'ref')}` : ''}`;
        item.iconPath = symbolIcon(symbol.kind);
        const tooltip = new vscode.MarkdownString();
        if (symbol.signature) {
          tooltip.appendCodeblock(symbol.signature, languageFor(symbol.path));
        }
        if (symbol.doc) {
          tooltip.appendMarkdown(`\n${symbol.doc}\n`);
        }
        tooltip.appendMarkdown(`\n${plural(references, 'reference')} · lines ${symbol.lines}`);
        item.tooltip = tooltip;
        const lines = parseLines(symbol.lines);
        item.command = { command: 'vesalius.openLocation', title: 'Open', arguments: [node.repository.uri(symbol.path), lines?.start] };
        return item;
      }
      case 'relation': {
        const { relation } = node;
        const { name, directory } = splitPath(relation.path);
        const item = new vscode.TreeItem(name, vscode.TreeItemCollapsibleState.None);
        item.resourceUri = node.repository.uri(relation.path);
        item.iconPath = vscode.ThemeIcon.File;
        const kinds = relation.kinds.length > 0 ? relation.kinds.join(', ') : node.direction === 'dependent' ? `distance ${relation.distance ?? 1}` : '';
        item.description = [directory, kinds].filter(Boolean).join(' · ');
        const verb = node.direction === 'dependent' ? 'uses' : 'is used through';
        item.tooltip = relation.symbols && relation.symbols.length > 0 ? `${relation.path} ${verb} ${relation.symbols.join(', ')}` : relation.path;
        item.command = { command: 'vesalius.openLocation', title: 'Open', arguments: [item.resourceUri] };
        return item;
      }
      case 'related': {
        const { name, directory } = splitPath(node.related.path);
        const item = new vscode.TreeItem(name, vscode.TreeItemCollapsibleState.None);
        item.resourceUri = node.repository.uri(node.related.path);
        item.iconPath = vscode.ThemeIcon.File;
        item.description = [directory, node.related.reason].filter(Boolean).join(' · ');
        item.tooltip = `${node.related.path}\n${node.related.reason}`;
        item.command = { command: 'vesalius.openLocation', title: 'Open', arguments: [item.resourceUri] };
        return item;
      }
      case 'diagnostic': {
        const { diagnostic } = node;
        const item = new vscode.TreeItem(diagnostic.title, vscode.TreeItemCollapsibleState.None);
        item.description = diagnostic.severity;
        item.iconPath = severityIcon(diagnostic.severity);
        item.tooltip = new vscode.MarkdownString(`**${diagnostic.title}**\n\n${diagnostic.summary}\n\n*Suggestion:* ${diagnostic.recommendation}`);
        const line = diagnostic.targets.find((t) => t.path === node.path && t.line)?.line;
        item.command = { command: 'vesalius.openLocation', title: 'Open', arguments: [node.repository.uri(node.path), line] };
        return item;
      }
      case 'message': {
        const item = new vscode.TreeItem(node.text, vscode.TreeItemCollapsibleState.None);
        item.description = node.detail;
        item.tooltip = node.detail;
        item.command = node.command;
        item.iconPath = new vscode.ThemeIcon('warning');
        return item;
      }
    }
  }

  getChildren(node?: CurrentFileNode): CurrentFileNode[] {
    if (!node) {
      if (this.error) {
        return [{ type: 'message', text: 'Could not load this file', detail: this.error, command: { command: 'vesalius.showOutput', title: 'Show Output' } }];
      }
      if (!this.context || !this.target) {
        return [];
      }
      const { context } = this;
      const { repository } = this.target;
      const roots: CurrentFileNode[] = [{ type: 'overview', context, repository }];
      if (context.diagnostics.length > 0) {
        roots.push({ type: 'group', group: 'findings', context, repository });
      }
      roots.push({ type: 'group', group: 'dependents', context, repository });
      roots.push({ type: 'group', group: 'dependencies', context, repository });
      roots.push({ type: 'group', group: 'symbols', context, repository });
      if (context.related.length > 0) {
        roots.push({ type: 'group', group: 'related', context, repository });
      }
      return roots;
    }
    if (node.type === 'group') {
      return this.groupChildren(node);
    }
    if (node.type === 'symbol') {
      return node.members.map((symbol) => ({ type: 'symbol', symbol, members: [], repository: node.repository }));
    }
    return [];
  }

  private groupChildren(node: Extract<CurrentFileNode, { type: 'group' }>): CurrentFileNode[] {
    const { context, repository } = node;
    switch (node.group) {
      case 'findings':
        return context.diagnostics.map((diagnostic) => ({ type: 'diagnostic', diagnostic, path: context.file.path, repository }));
      case 'dependents':
        return context.dependents.map((relation) => ({ type: 'relation', relation, direction: 'dependent', repository }));
      case 'dependencies':
        return context.dependencies.map((relation) => ({ type: 'relation', relation, direction: 'dependency', repository }));
      case 'related':
        return context.related.map((related) => ({ type: 'related', related, repository }));
      case 'symbols':
        return nestSymbols(context.symbols).map(({ symbol, members }) => ({ type: 'symbol', symbol, members, repository }));
    }
  }
}

/** Groups members (depth > 0) under the top-level declaration that precedes them. */
function nestSymbols(symbols: SymbolSummary[]): { symbol: SymbolSummary; members: SymbolSummary[] }[] {
  const result: { symbol: SymbolSummary; members: SymbolSummary[] }[] = [];
  for (const symbol of symbols) {
    const parent = result[result.length - 1];
    if ((symbol.depth ?? 0) > 0 && parent) {
      parent.members.push(symbol);
    } else {
      result.push({ symbol, members: [] });
    }
  }
  return result;
}

function languageFor(path: string): string {
  const extension = path.slice(path.lastIndexOf('.') + 1);
  return { ts: 'typescript', tsx: 'typescriptreact', js: 'javascript', jsx: 'javascriptreact', py: 'python', swift: 'swift', kt: 'kotlin', go: 'go', rs: 'rust', java: 'java' }[extension] ?? extension;
}
