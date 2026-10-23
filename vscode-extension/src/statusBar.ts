import * as vscode from 'vscode';
import { categoryTitles, HealthResult } from './types';

/** "$(pulse) Health 69" with a category breakdown tooltip; spins while the index updates. */
export class HealthStatusBar implements vscode.Disposable {
  readonly item = vscode.window.createStatusBarItem('vesalius.health', vscode.StatusBarAlignment.Left, 20);
  private health: HealthResult | undefined;
  private indexing = false;
  private cliMissing = false;
  private failure: string | undefined;

  constructor() {
    this.item.name = 'Vesalius Health';
    this.render();
  }

  dispose(): void {
    this.item.dispose();
  }

  setHealth(health: HealthResult | undefined): void {
    this.health = health;
    this.failure = undefined;
    this.render();
  }

  setIndexing(indexing: boolean): void {
    this.indexing = indexing;
    if (indexing) {
      this.failure = undefined;
    }
    this.render();
  }

  setCliMissing(missing: boolean): void {
    this.cliMissing = missing;
    this.render();
  }

  setFailure(message: string | undefined): void {
    this.failure = message;
    this.render();
  }

  private render(): void {
    const item = this.item;
    if (!vscode.workspace.workspaceFolders?.length) {
      item.hide();
      return;
    }
    item.backgroundColor = undefined;
    if (this.cliMissing) {
      item.text = '$(circle-slash) Vesalius';
      item.tooltip = 'The Vesalius command line tool was not found. Click to install it.';
      item.command = 'vesalius.installCli';
    } else if (this.indexing) {
      item.text = this.health ? `$(sync~spin) Health ${this.health.health.score}` : '$(sync~spin) Vesalius';
      item.tooltip = 'Vesalius is updating the index…';
      item.command = 'vesalius.showOutput';
    } else if (this.failure) {
      item.text = '$(warning) Vesalius';
      item.tooltip = `Vesalius could not update the index: ${this.failure}\n\nClick to show the log.`;
      item.command = 'vesalius.showOutput';
      item.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
    } else if (this.health) {
      const { health } = this.health;
      item.text = `$(pulse) Health ${health.score}`;
      item.tooltip = tooltip(this.health);
      item.command = 'vesalius.showHealth';
    } else {
      item.text = '$(pulse) Vesalius';
      item.tooltip = 'Vesalius: Code Anatomy';
      item.command = 'vesalius.showHealth';
    }
    item.show();
  }
}

function tooltip(result: HealthResult): vscode.MarkdownString {
  const { health } = result;
  const markdown = new vscode.MarkdownString(undefined, true);
  markdown.appendMarkdown(`**Health ${health.score}/100 · ${health.grade}**\n\n`);
  markdown.appendMarkdown(`| Category | Score |\n|:--|--:|\n`);
  for (const category of health.categories) {
    markdown.appendMarkdown(`| ${categoryTitles[category.category] ?? category.category} | ${category.score} |\n`);
  }
  const counts = (['critical', 'high', 'medium', 'low'] as const)
    .map((severity) => [severity, health.diagnosticCounts[severity] ?? 0] as const)
    .filter(([, count]) => count > 0)
    .map(([severity, count]) => `${count} ${severity}`);
  markdown.appendMarkdown(`\n${counts.length > 0 ? `Findings: ${counts.join(' · ')}` : 'No findings'}\n\n`);
  markdown.appendMarkdown('Click to open the Health view.');
  return markdown;
}
