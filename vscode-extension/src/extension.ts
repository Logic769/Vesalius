import * as vscode from 'vscode';
import { CliLocation } from './cli';
import { VesaliusCodeLensProvider } from './codeLens';
import { registerCommands } from './commands';
import { Vesalius } from './controller';
import { DiagnosticsController } from './diagnostics';
import { ImpactPanel } from './impactPanel';
import { McpRegistration } from './mcp';
import { Repositories } from './repository';
import { HealthStatusBar } from './statusBar';
import { CurrentFileTreeProvider } from './views/currentFileTree';
import { HealthTreeProvider } from './views/healthTree';
import { AskResult } from './types';
import { HotspotsTreeProvider } from './views/hotspotsTree';

/** What `activate` returns: the live pieces, for other extensions and the end-to-end tests. */
export interface VesaliusApi {
  readonly repositories: Repositories;
  readonly health: HealthTreeProvider;
  readonly currentFile: CurrentFileTreeProvider;
  readonly hotspots: HotspotsTreeProvider;
  readonly diagnostics: DiagnosticsController;
  readonly codeLens: VesaliusCodeLensProvider;
  readonly impact: ImpactPanel;
  readonly statusBar: HealthStatusBar;
  readonly mcp: McpRegistration;
  readonly cli: CliLocation | undefined;
  /** Fires when "Ask the Codebase" shows an answer. */
  readonly onDidAnswer: vscode.Event<AskResult>;
  /** Settles when the current background indexing and view refreshes have finished. */
  readonly ready: Promise<void>;
}

export function activate(context: vscode.ExtensionContext): VesaliusApi {
  const vesalius = new Vesalius(context);
  context.subscriptions.push(vesalius, ...registerCommands(vesalius));
  vesalius.start();
  return {
    repositories: vesalius.repositories,
    health: vesalius.health,
    currentFile: vesalius.currentFile,
    hotspots: vesalius.hotspots,
    diagnostics: vesalius.diagnostics,
    codeLens: vesalius.codeLens,
    impact: vesalius.impact,
    statusBar: vesalius.statusBar,
    mcp: vesalius.mcp,
    onDidAnswer: vesalius.answered.event,
    get cli() {
      return vesalius.cliLocation;
    },
    get ready() {
      return vesalius.ready.then(() => vesalius.settle());
    },
  };
}

export function deactivate(): void {
  // Everything is disposed through the extension context.
}
