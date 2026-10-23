import * as vscode from 'vscode';
import { CliNotFoundError } from '../cli';
import { Repositories, Repository } from '../repository';
import { categoryTitles, CategoryScore, Diagnostic, HealthResult, ScoreFactor, Severity } from '../types';
import { errorMessage, severityIcon, splitPath } from '../util';

export type HealthNode =
  | { type: 'summary'; result: HealthResult }
  | { type: 'categories'; result: HealthResult }
  | { type: 'category'; category: CategoryScore }
  | { type: 'factor'; factor: ScoreFactor }
  | { type: 'severity'; severity: Severity; diagnostics: Diagnostic[] }
  | { type: 'diagnostic'; diagnostic: Diagnostic; repository: Repository }
  | { type: 'message'; text: string; detail?: string; command?: vscode.Command };

/** Repository health: score, the eight categories with their deductions, and top findings. */
export class HealthTreeProvider implements vscode.TreeDataProvider<HealthNode> {
  private readonly changed = new vscode.EventEmitter<HealthNode | undefined>();
  readonly onDidChangeTreeData = this.changed.event;
  private result: HealthResult | undefined;
  private error: string | undefined;

  constructor(private readonly repositories: Repositories) {}

  /** The loaded health report (used by the status bar). */
  get current(): HealthResult | undefined {
    return this.result;
  }

  refresh(): Promise<void> {
    const repository = this.repositories.active;
    if (!repository) {
      this.result = undefined;
      this.changed.fire(undefined);
      return Promise.resolve();
    }
    return repository
      .health()
      .then((result) => {
        this.result = result;
        this.error = undefined;
      })
      .catch((error: unknown) => {
        if (error instanceof CliNotFoundError) {
          this.result = undefined;
          this.error = undefined;
        } else {
          this.error = errorMessage(error);
        }
      })
      .finally(() => this.changed.fire(undefined));
  }

  getTreeItem(node: HealthNode): vscode.TreeItem {
    switch (node.type) {
      case 'summary': {
        const health = node.result.health;
        const item = new vscode.TreeItem(`Health ${health.score} · ${health.grade}`, vscode.TreeItemCollapsibleState.None);
        item.iconPath = new vscode.ThemeIcon('pulse');
        const total = Object.values(health.diagnosticCounts).reduce((sum, count) => sum + count, 0);
        item.description = total === 1 ? '1 finding' : `${total} findings`;
        item.tooltip = new vscode.MarkdownString(`**Health ${health.score}/100 (${health.grade})**\n\n${health.summary}`);
        return item;
      }
      case 'categories': {
        const item = new vscode.TreeItem('Score breakdown', vscode.TreeItemCollapsibleState.Expanded);
        item.iconPath = new vscode.ThemeIcon('graph');
        return item;
      }
      case 'category': {
        const title = categoryTitles[node.category.category] ?? node.category.category;
        const hasDeductions = node.category.factors.length > 0;
        const item = new vscode.TreeItem(title, hasDeductions ? vscode.TreeItemCollapsibleState.Collapsed : vscode.TreeItemCollapsibleState.None);
        item.description = `${node.category.score}`;
        item.tooltip = new vscode.MarkdownString(`**${title}: ${node.category.score}/100**\n\n${node.category.summary}`);
        item.iconPath = new vscode.ThemeIcon(node.category.score >= 85 ? 'pass' : node.category.score >= 55 ? 'circle-large-outline' : 'warning');
        return item;
      }
      case 'factor': {
        const sign = node.factor.impact > 0 ? '+' : '';
        const item = new vscode.TreeItem(`${sign}${node.factor.impact.toFixed(1)}  ${node.factor.label}`, vscode.TreeItemCollapsibleState.None);
        item.description = node.factor.detail;
        item.tooltip = node.factor.detail;
        return item;
      }
      case 'severity': {
        const label = node.severity[0].toUpperCase() + node.severity.slice(1);
        const expanded = node.severity === 'critical' || node.severity === 'high';
        const item = new vscode.TreeItem(label, expanded ? vscode.TreeItemCollapsibleState.Expanded : vscode.TreeItemCollapsibleState.Collapsed);
        item.description = `${node.diagnostics.length}`;
        item.iconPath = severityIcon(node.severity);
        return item;
      }
      case 'diagnostic': {
        const diagnostic = node.diagnostic;
        const target = diagnostic.targets.find((t) => t.kind === 'file' || t.kind === 'symbol') ?? diagnostic.targets[0];
        const item = new vscode.TreeItem(diagnostic.title, vscode.TreeItemCollapsibleState.None);
        item.description = target ? splitPath(target.path).name : undefined;
        item.iconPath = severityIcon(diagnostic.severity);
        item.tooltip = new vscode.MarkdownString(`**${diagnostic.title}**\n\n${diagnostic.summary}\n\n*Why:* ${diagnostic.reason}\n\n*Suggestion:* ${diagnostic.recommendation}`);
        if (target && (target.kind === 'file' || target.kind === 'symbol')) {
          item.command = { command: 'vesalius.openLocation', title: 'Open', arguments: [node.repository.uri(target.path), target.line] };
        }
        return item;
      }
      case 'message': {
        const item = new vscode.TreeItem(node.text, vscode.TreeItemCollapsibleState.None);
        item.description = node.detail;
        item.command = node.command;
        item.iconPath = new vscode.ThemeIcon('info');
        return item;
      }
    }
  }

  getChildren(node?: HealthNode): HealthNode[] {
    if (!node) {
      if (this.error) {
        return [{ type: 'message', text: 'Health unavailable', detail: this.error, command: { command: 'vesalius.showOutput', title: 'Show Output' } }];
      }
      if (!this.result) {
        return [];
      }
      const roots: HealthNode[] = [{ type: 'summary', result: this.result }, { type: 'categories', result: this.result }];
      const repository = this.repositories.active;
      for (const severity of ['critical', 'high', 'medium', 'low'] as Severity[]) {
        const diagnostics = this.result.diagnostics.filter((d) => d.severity === severity);
        if (diagnostics.length > 0 && repository) {
          roots.push({ type: 'severity', severity, diagnostics });
        }
      }
      return roots;
    }
    switch (node.type) {
      case 'categories':
        return node.result.health.categories.map((category) => ({ type: 'category', category }));
      case 'category':
        return node.category.factors.map((factor) => ({ type: 'factor', factor }));
      case 'severity': {
        const repository = this.repositories.active;
        return repository ? node.diagnostics.map((diagnostic) => ({ type: 'diagnostic', diagnostic, repository })) : [];
      }
      default:
        return [];
    }
  }
}
