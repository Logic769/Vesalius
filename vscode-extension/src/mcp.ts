import * as vscode from 'vscode';
import { CliLocation } from './cli';
import { Repositories } from './repository';

/** A stdio MCP server launch: `<cli> mcp --repo <folder>`. */
export interface McpServerLaunch {
  label: string;
  command: string;
  args: string[];
  env: Record<string, string>;
  folder: vscode.Uri;
}

export function mcpLaunches(repositories: Repositories, location: CliLocation | undefined): McpServerLaunch[] {
  if (!location) {
    return [];
  }
  const all = repositories.all;
  // Keep a non-default index location (VESALIUS_HOME) so the server reads the index this window uses.
  const env: Record<string, string> = process.env.VESALIUS_HOME ? { VESALIUS_HOME: process.env.VESALIUS_HOME } : {};
  return all.map((repository) => ({
    label: all.length > 1 ? `Vesalius (${repository.folder.name})` : 'Vesalius',
    command: location.command,
    args: [...location.prefixArgs, 'mcp', '--repo', repository.root],
    env,
    folder: repository.folder.uri,
  }));
}

/**
 * Registers Vesalius as an MCP server for VS Code's agent mode when the running VS Code has the API
 * (1.101 and later). On older versions this is a no-op; "Vesalius: Copy MCP Config" still works.
 */
export class McpRegistration implements vscode.Disposable {
  readonly registered: boolean;
  private readonly changed = new vscode.EventEmitter<void>();
  private readonly registration: vscode.Disposable | undefined;

  constructor(
    private readonly repositories: Repositories,
    private readonly location: () => CliLocation | undefined,
    log: vscode.OutputChannel,
  ) {
    // Typed loosely: the MCP API is newer than the minimum engine this extension supports.
    const api = vscode as any;
    const register = api.lm?.registerMcpServerDefinitionProvider;
    const Definition = api.McpStdioServerDefinition;
    if (typeof register !== 'function' || typeof Definition !== 'function') {
      this.registered = false;
      log.appendLine('MCP server registration is not available in this VS Code version; use "Vesalius: Copy MCP Config" instead.');
      return;
    }
    let registration: vscode.Disposable | undefined;
    try {
      registration = register.call(api.lm, 'vesalius.mcp', {
        onDidChangeMcpServerDefinitions: this.changed.event,
        provideMcpServerDefinitions: () =>
          this.launches().map((launch) => {
            const definition = new Definition(launch.label, launch.command, launch.args, launch.env);
            definition.cwd = launch.folder;
            return definition;
          }),
      }) as vscode.Disposable;
    } catch (error) {
      log.appendLine(`Could not register the Vesalius MCP server: ${error instanceof Error ? error.message : String(error)}`);
    }
    this.registration = registration;
    this.registered = registration !== undefined;
  }

  launches(): McpServerLaunch[] {
    return mcpLaunches(this.repositories, this.location());
  }

  /** Tells VS Code the server list changed (folders added or the CLI moved). */
  refresh(): void {
    this.changed.fire();
  }

  dispose(): void {
    this.registration?.dispose();
    this.changed.dispose();
  }
}
