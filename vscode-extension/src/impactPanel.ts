import { randomBytes } from 'crypto';
import * as vscode from 'vscode';
import { Repository } from './repository';
import { FileRelation, ImpactReport, ReferenceSite, RiskLevel } from './types';
import { errorMessage, openLocation, plural, splitPath } from './util';

interface PanelState {
  repository: Repository;
  target: string;
  label: string;
  report: ImpactReport;
}

export type InboundMessage =
  | { type: 'open'; path: string; line?: number }
  | { type: 'openInApp' }
  | { type: 'copy' }
  | { type: 'refresh' };

/**
 * The "Blast Radius" webview: what changing a file or symbol affects, why it is risky, and where
 * the call sites are. Styled only with the theme's CSS variables; paths open via postMessage.
 */
export class ImpactPanel implements vscode.Disposable {
  private panel: vscode.WebviewPanel | undefined;
  private state: PanelState | undefined;
  private readonly disposables: vscode.Disposable[] = [];

  constructor(
    private readonly extensionUri: vscode.Uri,
    private readonly openInApp: (repository: Repository, options: Record<string, string>) => Promise<void>,
  ) {}

  dispose(): void {
    this.panel?.dispose();
    this.disposables.forEach((d) => d.dispose());
  }

  /** The report on screen, if the panel is open. */
  get current(): PanelState | undefined {
    return this.panel ? this.state : undefined;
  }

  /** The rendered page, if the panel is open. */
  get html(): string | undefined {
    return this.panel?.webview.html;
  }

  /** Computes the impact of `target` (a repository-relative path or symbol) and shows it. */
  async show(repository: Repository, target: string, label: string): Promise<ImpactReport> {
    const report = await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Window, title: `$(sync~spin) Vesalius: blast radius of ${label}` },
      (_progress, token) => repository.impact(target, token),
    );
    this.state = { repository, target, label, report };
    const panel = this.ensurePanel();
    panel.title = `Blast Radius: ${label}`;
    panel.webview.html = render(panel.webview, report, label);
    panel.reveal(panel.viewColumn ?? vscode.ViewColumn.Beside, false);
    return report;
  }

  private ensurePanel(): vscode.WebviewPanel {
    if (this.panel) {
      return this.panel;
    }
    const panel = vscode.window.createWebviewPanel('vesalius.blastRadius', 'Blast Radius', { viewColumn: vscode.ViewColumn.Beside, preserveFocus: false }, {
      enableScripts: true,
      enableFindWidget: true,
      retainContextWhenHidden: false,
      localResourceRoots: [],
    });
    panel.iconPath = {
      light: vscode.Uri.joinPath(this.extensionUri, 'media', 'blast-light.svg'),
      dark: vscode.Uri.joinPath(this.extensionUri, 'media', 'blast-dark.svg'),
    };
    panel.onDidDispose(() => {
      this.panel = undefined;
    }, undefined, this.disposables);
    panel.webview.onDidReceiveMessage((message: InboundMessage) => this.receive(message), undefined, this.disposables);
    this.panel = panel;
    return panel;
  }

  /** Handles a message posted by the page (a click on a path or an action button). */
  async receive(message: InboundMessage): Promise<void> {
    const state = this.state;
    if (!state) {
      return;
    }
    try {
      switch (message.type) {
        case 'open': {
          const column = vscode.window.visibleTextEditors.find((editor) => editor.viewColumn !== this.panel?.viewColumn)?.viewColumn ?? vscode.ViewColumn.One;
          await openLocation(state.repository.uri(message.path), message.line, undefined, column);
          break;
        }
        case 'openInApp':
          await this.openInApp(state.repository, { impact: state.target });
          break;
        case 'copy':
          await vscode.env.clipboard.writeText(summaryText(state.report));
          vscode.window.setStatusBarMessage('$(check) Blast radius copied', 2500);
          break;
        case 'refresh':
          await this.show(state.repository, state.target, state.label);
          break;
      }
    } catch (error) {
      void vscode.window.showErrorMessage(`Vesalius: ${errorMessage(error)}`);
    }
  }
}

// MARK: Rendering

function escape(text: string | number | undefined): string {
  return String(text ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] ?? c);
}

function riskTitle(level: RiskLevel): string {
  return `${level[0].toUpperCase()}${level.slice(1)} risk`;
}

function fileLink(path: string, line?: number, text?: string): string {
  const { name, directory } = splitPath(path);
  const label = text ?? name;
  const location = line ? `:${line}` : '';
  return `<button class="link" data-path="${escape(path)}"${line ? ` data-line="${line}"` : ''} title="Open ${escape(path)}${location}">` +
    `<span class="name">${escape(label)}${escape(location)}</span>${directory && !text ? `<span class="dir">${escape(directory)}</span>` : ''}</button>`;
}

function relationRows(relations: FileRelation[], showDistance: boolean): string {
  return relations
    .map((relation) => {
      const chips = relation.kinds.map((kind) => `<span class="chip">${escape(kind)}</span>`).join('');
      const symbols = relation.symbols && relation.symbols.length > 0 ? `<div class="sub">uses ${relation.symbols.map((s) => `<code>${escape(s)}</code>`).join(', ')}</div>` : '';
      const distance = showDistance ? `<span class="chip quiet">${relation.distance ?? 1} hop${(relation.distance ?? 1) === 1 ? '' : 's'}</span>` : '';
      return `<li><div class="row">${fileLink(relation.path)}<span class="chips">${chips}${distance}</span></div>${symbols}</li>`;
    })
    .join('');
}

function callRows(callers: ReferenceSite[]): string {
  return callers
    .map((site) => {
      const from = site.from ? `<span class="chip quiet">in ${escape(site.from)}</span>` : '';
      const snippet = site.snippet ? `<pre><code>${escape(site.snippet.trim())}</code></pre>` : '';
      return `<li><div class="row">${fileLink(site.path, site.line)}<span class="chips"><span class="chip">${escape(site.kind)}</span>${from}</span></div>${snippet}</li>`;
    })
    .join('');
}

function section(title: string, count: number | undefined, body: string, empty: string): string {
  const badge = count === undefined ? '' : `<span class="count">${count}</span>`;
  return `<section><h2>${escape(title)}${badge}</h2>${body ? body : `<p class="empty">${escape(empty)}</p>`}</section>`;
}

function render(webview: vscode.Webview, report: ImpactReport, label: string): string {
  const nonce = randomBytes(16).toString('base64');
  const callers = report.callers ?? [];
  const maxImpact = Math.max(1, ...report.factors.map((factor) => Math.abs(factor.impact)));
  const factors = report.factors
    .map((factor) => {
      const width = Math.max(4, Math.round((Math.abs(factor.impact) / maxImpact) * 100));
      return `<li class="factor"><div class="row"><span class="factor-label">${escape(factor.label)}</span><span class="factor-value">+${escape(factor.impact.toFixed(1))}</span></div>` +
        `<div class="bar"><span data-width="${width}"></span></div><div class="sub">${escape(factor.detail)}</div></li>`;
    })
    .join('');
  const areas = report.affectedAreas.map((area) => `<span class="chip">${escape(area.name)} <b>${area.files}</b></span>`).join('');
  const tests = report.relatedTests.map((path) => `<li><div class="row">${fileLink(path)}</div></li>`).join('');
  const symbols = report.symbols && report.symbols.length > 0 ? report.symbols.map((s) => `${s.kind} <code>${escape(s.qualifiedName)}</code>`).join(', ') : undefined;

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'nonce-${nonce}' ${webview.cspSource}; script-src 'nonce-${nonce}';">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Blast Radius</title>
<style nonce="${nonce}">
  :root { --gap: 16px; }
  body { font-family: var(--vscode-font-family); font-size: var(--vscode-font-size); color: var(--vscode-foreground); background: var(--vscode-editor-background); margin: 0; padding: 24px 28px 40px; line-height: 1.5; }
  main { max-width: 880px; margin: 0 auto; }
  header { display: flex; align-items: flex-start; justify-content: space-between; gap: var(--gap); flex-wrap: wrap; }
  .eyebrow { text-transform: uppercase; letter-spacing: .08em; font-size: 11px; color: var(--vscode-descriptionForeground); }
  h1 { font-size: 22px; font-weight: 600; margin: 2px 0 2px; word-break: break-all; }
  .target { font-family: var(--vscode-editor-font-family); font-size: 12px; color: var(--vscode-descriptionForeground); word-break: break-all; }
  .risk { display: inline-flex; align-items: center; gap: 8px; padding: 6px 12px; border-radius: 999px; border: 1px solid var(--vscode-panel-border); font-weight: 600; white-space: nowrap; }
  .risk .dot { width: 10px; height: 10px; border-radius: 50%; background: currentColor; }
  .risk .score { font-weight: 400; color: var(--vscode-descriptionForeground); }
  .risk-low { color: var(--vscode-charts-green); }
  .risk-moderate { color: var(--vscode-charts-yellow); }
  .risk-high { color: var(--vscode-charts-orange); }
  .risk-critical { color: var(--vscode-charts-red); }
  .summary { margin: 14px 0 20px; font-size: 14px; }
  .symbols { color: var(--vscode-descriptionForeground); margin-top: -12px; margin-bottom: 18px; }
  .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin-bottom: 8px; }
  .stat { border: 1px solid var(--vscode-panel-border); border-radius: 8px; padding: 12px 14px; background: var(--vscode-editorWidget-background); }
  .stat .value { font-size: 24px; font-weight: 600; font-variant-numeric: tabular-nums; }
  .stat .label { color: var(--vscode-descriptionForeground); font-size: 12px; }
  section { margin-top: 26px; }
  h2 { font-size: 13px; font-weight: 600; text-transform: uppercase; letter-spacing: .06em; color: var(--vscode-descriptionForeground); margin: 0 0 10px; display: flex; align-items: center; gap: 8px; border-bottom: 1px solid var(--vscode-panel-border); padding-bottom: 6px; }
  .count { font-size: 11px; font-weight: 600; padding: 0 7px; border-radius: 999px; background: var(--vscode-badge-background); color: var(--vscode-badge-foreground); letter-spacing: 0; }
  ul { list-style: none; padding: 0; margin: 0; }
  li { padding: 7px 0; border-bottom: 1px solid var(--vscode-widget-border, transparent); }
  li:last-child { border-bottom: none; }
  .row { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
  .sub { color: var(--vscode-descriptionForeground); font-size: 12px; margin-top: 2px; }
  .chips { display: inline-flex; gap: 6px; flex-wrap: wrap; }
  .chip { font-size: 11px; padding: 1px 8px; border-radius: 999px; border: 1px solid var(--vscode-panel-border); color: var(--vscode-foreground); white-space: nowrap; }
  .chip.quiet { color: var(--vscode-descriptionForeground); }
  .areas { display: flex; gap: 8px; flex-wrap: wrap; }
  button.link { all: unset; cursor: pointer; display: inline-flex; gap: 8px; align-items: baseline; color: var(--vscode-textLink-foreground); border-radius: 3px; }
  button.link:hover .name { text-decoration: underline; color: var(--vscode-textLink-activeForeground); }
  button.link:focus-visible { outline: 1px solid var(--vscode-focusBorder); outline-offset: 2px; }
  button.link .name { font-family: var(--vscode-editor-font-family); font-size: 13px; }
  button.link .dir { color: var(--vscode-descriptionForeground); font-size: 12px; }
  code { font-family: var(--vscode-editor-font-family); font-size: 12px; }
  pre { margin: 6px 0 0; padding: 8px 10px; border-radius: 6px; background: var(--vscode-textCodeBlock-background); overflow-x: auto; }
  .factor .row { align-items: center; }
  .factor-value { font-variant-numeric: tabular-nums; color: var(--vscode-descriptionForeground); }
  .bar { height: 4px; border-radius: 2px; background: var(--vscode-editorWidget-border, var(--vscode-panel-border)); margin: 6px 0 2px; overflow: hidden; }
  .bar span { display: block; height: 100%; background: var(--vscode-progressBar-background); border-radius: 2px; }
  .empty { color: var(--vscode-descriptionForeground); margin: 4px 0; }
  .actions { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 32px; }
  .actions button { font-family: inherit; font-size: 13px; padding: 5px 14px; border-radius: 4px; border: 1px solid var(--vscode-button-border, transparent); cursor: pointer; color: var(--vscode-button-secondaryForeground); background: var(--vscode-button-secondaryBackground); }
  .actions button:hover { background: var(--vscode-button-secondaryHoverBackground); }
  .actions button.primary { color: var(--vscode-button-foreground); background: var(--vscode-button-background); }
  .actions button.primary:hover { background: var(--vscode-button-hoverBackground); }
  .actions button:focus-visible { outline: 1px solid var(--vscode-focusBorder); outline-offset: 2px; }
</style>
</head>
<body>
<main>
  <header>
    <div>
      <div class="eyebrow">Blast radius · ${escape(report.targetKind)}</div>
      <h1>${escape(label)}</h1>
      <div class="target">${escape(report.target)}</div>
    </div>
    <div class="risk risk-${escape(report.riskLevel)}" role="status" aria-label="${escape(riskTitle(report.riskLevel))}, score ${Math.round(report.riskScore)} of 100"><span class="dot"></span>${escape(riskTitle(report.riskLevel))}<span class="score">${Math.round(report.riskScore)}/100</span></div>
  </header>
  <p class="summary">${escape(report.summary)}</p>
  ${symbols ? `<p class="symbols">Declared here: ${symbols}</p>` : ''}
  <div class="stats">
    <div class="stat"><div class="value">${report.directDependents.length}</div><div class="label">direct ${report.directDependents.length === 1 ? 'dependent' : 'dependents'}</div></div>
    <div class="stat"><div class="value">${report.transitiveDependents.length}</div><div class="label">transitive ${report.transitiveDependents.length === 1 ? 'dependent' : 'dependents'}</div></div>
    <div class="stat"><div class="value">${callers.length}</div><div class="label">${callers.length === 1 ? 'call site' : 'call sites'}</div></div>
    <div class="stat"><div class="value">${report.relatedTests.length}</div><div class="label">related ${report.relatedTests.length === 1 ? 'test' : 'tests'}</div></div>
  </div>
  ${section('Why this risk', undefined, factors ? `<ul>${factors}</ul>` : '', 'Nothing raises the risk of this change.')}
  ${section('Direct dependents', report.directDependents.length, report.directDependents.length ? `<ul>${relationRows(report.directDependents, false)}</ul>` : '', 'Nothing in the index depends on this directly. Changes stay local.')}
  ${section('Transitive dependents', report.transitiveDependents.length, report.transitiveDependents.length ? `<ul>${relationRows(report.transitiveDependents, true)}</ul>` : '', 'No files are affected further away.')}
  ${section('Call sites', callers.length, callers.length ? `<ul>${callRows(callers)}</ul>` : '', 'No resolved call sites.')}
  ${section('Related tests', report.relatedTests.length, tests ? `<ul>${tests}</ul>` : '', 'No tests cover the affected files. Consider adding one before changing this.')}
  ${report.affectedAreas.length ? section('Affected areas', report.affectedAreas.length, `<div class="areas">${areas}</div>`, '') : ''}
  <div class="actions">
    <button class="primary" data-action="openInApp" title="Open this blast radius in the Vesalius app">Open in Vesalius</button>
    <button data-action="copy" title="Copy a Markdown summary">Copy Summary</button>
    <button data-action="refresh" title="Recompute from the current index">Refresh</button>
  </div>
</main>
<script nonce="${nonce}">
  const vscode = acquireVsCodeApi();
  for (const bar of document.querySelectorAll('.bar span[data-width]')) {
    bar.style.width = bar.dataset.width + '%';
  }
  document.addEventListener('click', (event) => {
    const element = event.target instanceof Element ? event.target.closest('button') : null;
    if (!element) { return; }
    if (element.dataset.path) {
      vscode.postMessage({ type: 'open', path: element.dataset.path, line: element.dataset.line ? Number(element.dataset.line) : undefined });
    } else if (element.dataset.action) {
      vscode.postMessage({ type: element.dataset.action });
    }
  });
</script>
</body>
</html>`;
}

function summaryText(report: ImpactReport): string {
  const lines = [`## Blast radius: ${report.target}`, '', `${riskTitle(report.riskLevel)} (${Math.round(report.riskScore)}/100). ${report.summary}`, ''];
  if (report.directDependents.length > 0) {
    lines.push(`Direct dependents (${report.directDependents.length}):`, ...report.directDependents.map((d) => `- ${d.path}${d.kinds.length ? ` (${d.kinds.join(', ')})` : ''}`), '');
  }
  if (report.transitiveDependents.length > 0) {
    lines.push(`Transitive dependents (${report.transitiveDependents.length}):`, ...report.transitiveDependents.map((d) => `- ${d.path}`), '');
  }
  if ((report.callers ?? []).length > 0) {
    lines.push(`Call sites (${report.callers.length}):`, ...report.callers.map((c) => `- ${c.path}:${c.line}${c.from ? ` in ${c.from}` : ''}`), '');
  }
  lines.push(report.relatedTests.length > 0 ? `Related tests: ${report.relatedTests.join(', ')}` : 'No related tests found.');
  lines.push('', `Risk factors: ${report.factors.map((f) => `${f.label} (${f.detail})`).join('; ') || 'none'}.`);
  return `${lines.join('\n')}\n\n_${plural(report.directDependents.length + report.transitiveDependents.length, 'affected file')}, from Vesalius._\n`;
}
