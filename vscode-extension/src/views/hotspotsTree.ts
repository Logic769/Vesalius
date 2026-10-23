import * as vscode from 'vscode';
import { CliNotFoundError } from '../cli';
import { Repositories, Repository } from '../repository';
import { Hotspot } from '../types';
import { errorMessage, splitPath } from '../util';

type HotspotNode =
  | { type: 'hotspot'; hotspot: Hotspot; rank: number; repository: Repository }
  | { type: 'reason'; text: string }
  | { type: 'message'; text: string; detail?: string };

/** Files where size, complexity, coupling, churn and findings concentrate. Loads when visible. */
export class HotspotsTreeProvider implements vscode.TreeDataProvider<HotspotNode> {
  private readonly changed = new vscode.EventEmitter<HotspotNode | undefined>();
  readonly onDidChangeTreeData = this.changed.event;
  private hotspots: { repository: Repository; items: Hotspot[] } | undefined;
  private error: string | undefined;
  private stale = true;

  constructor(private readonly repositories: Repositories) {}

  /** Marks the list out of date; it reloads the next time the view asks for it. */
  invalidate(): void {
    this.stale = true;
    this.changed.fire(undefined);
  }

  private async load(): Promise<void> {
    const repository = this.repositories.active;
    this.stale = false;
    if (!repository) {
      this.hotspots = undefined;
      return;
    }
    try {
      this.hotspots = { repository, items: await repository.hotspots() };
      this.error = undefined;
    } catch (error) {
      this.hotspots = undefined;
      this.error = error instanceof CliNotFoundError ? undefined : errorMessage(error);
    }
  }

  getTreeItem(node: HotspotNode): vscode.TreeItem {
    switch (node.type) {
      case 'hotspot': {
        const { hotspot } = node;
        const { name, directory } = splitPath(hotspot.path);
        const item = new vscode.TreeItem(name, vscode.TreeItemCollapsibleState.Collapsed);
        item.resourceUri = node.repository.uri(hotspot.path);
        const percent = Math.round(hotspot.score * 100);
        item.description = `${percent} · ${directory}`;
        const color = hotspot.score >= 0.5 ? 'list.errorForeground' : hotspot.score >= 0.25 ? 'list.warningForeground' : undefined;
        item.iconPath = new vscode.ThemeIcon('flame', color ? new vscode.ThemeColor(color) : undefined);
        const tooltip = new vscode.MarkdownString(`**#${node.rank} ${hotspot.path}** · hotspot score ${percent}\n\n`);
        tooltip.appendMarkdown(`| | |\n|---|---|\n| Lines of code | ${hotspot.lines} |\n| Complexity | ${hotspot.complexity} |\n| Fan-in / fan-out | ${hotspot.fanIn} / ${hotspot.fanOut} |\n`);
        if (hotspot.churn !== undefined) {
          tooltip.appendMarkdown(`| Commits (churn) | ${hotspot.churn} |\n`);
        }
        tooltip.appendMarkdown(`| Findings | ${hotspot.diagnostics} |\n`);
        item.tooltip = tooltip;
        item.command = { command: 'vesalius.openLocation', title: 'Open', arguments: [item.resourceUri] };
        return item;
      }
      case 'reason': {
        const item = new vscode.TreeItem(node.text, vscode.TreeItemCollapsibleState.None);
        item.iconPath = new vscode.ThemeIcon('circle-small');
        return item;
      }
      case 'message': {
        const item = new vscode.TreeItem(node.text, vscode.TreeItemCollapsibleState.None);
        item.description = node.detail;
        item.tooltip = node.detail;
        item.iconPath = new vscode.ThemeIcon('warning');
        item.command = { command: 'vesalius.showOutput', title: 'Show Output' };
        return item;
      }
    }
  }

  async getChildren(node?: HotspotNode): Promise<HotspotNode[]> {
    if (node) {
      return node.type === 'hotspot' ? node.hotspot.reasons.map((text) => ({ type: 'reason', text })) : [];
    }
    if (this.stale) {
      await this.load();
    }
    if (this.error) {
      return [{ type: 'message', text: 'Hotspots unavailable', detail: this.error }];
    }
    const hotspots = this.hotspots;
    return hotspots ? hotspots.items.map((hotspot, index) => ({ type: 'hotspot', hotspot, rank: index + 1, repository: hotspots.repository })) : [];
  }
}
