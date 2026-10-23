import { spawn } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import * as vscode from 'vscode';

/** Where the `vesalius` command was found and how to invoke it. */
export interface CliLocation {
  command: string;
  /** Extra leading arguments (the app binary needs `--cli` to act as the command line tool). */
  prefixArgs: string[];
  /** Human description of where it came from, for the output log. */
  source: string;
}

export class CliNotFoundError extends Error {
  constructor(readonly configuredPath?: string) {
    super(
      configuredPath
        ? `The configured Vesalius CLI does not exist or is not executable: ${configuredPath}`
        : 'The Vesalius command line tool was not found. Run "Vesalius: Install Vesalius CLI", install it from the Vesalius app (Settings > Agents > Install for My User), or set "vesalius.cliPath".',
    );
    this.name = 'CliNotFoundError';
  }
}

/** A failed CLI invocation. `message` is the CLI's own error text when it printed one. */
export class CliError extends Error {
  constructor(
    message: string,
    readonly suggestions: string[] = [],
    readonly exitCode?: number | null,
    readonly stderr?: string,
  ) {
    super(message);
    this.name = 'CliError';
  }

  get isNotIndexed(): boolean {
    return /has not been indexed yet/.test(this.message);
  }

  get isNotFound(): boolean {
    return /Nothing in the index matches/.test(this.message);
  }
}

const appBinaries = [
  '/Applications/Vesalius.app/Contents/MacOS/Vesalius',
  path.join(os.homedir(), 'Applications/Vesalius.app/Contents/MacOS/Vesalius'),
];

function isExecutable(file: string): boolean {
  try {
    const stat = fs.statSync(file);
    if (!stat.isFile()) {
      return false;
    }
    fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function expandHome(file: string): string {
  return file.startsWith('~/') ? path.join(os.homedir(), file.slice(2)) : file;
}

function locationFor(command: string, source: string): CliLocation {
  const isAppBinary = command.endsWith('/Contents/MacOS/Vesalius');
  return { command, prefixArgs: isAppBinary ? ['--cli'] : [], source };
}

/**
 * Finds the CLI: the `vesalius.cliPath` setting, the `VESALIUS_CLI_PATH` environment variable,
 * `vesalius` on PATH, `~/.local/bin`, `/usr/local/bin`, `/opt/homebrew/bin`, the app bundle, then a
 * development build inside the workspace (`VesaliusKit/.build/{release,debug}/vesalius`).
 */
export function resolveCli(folders: readonly vscode.WorkspaceFolder[] = vscode.workspace.workspaceFolders ?? []): CliLocation {
  const configured = vscode.workspace.getConfiguration('vesalius').get<string>('cliPath')?.trim();
  if (configured) {
    const file = expandHome(configured);
    if (isExecutable(file)) {
      return locationFor(file, 'vesalius.cliPath setting');
    }
    throw new CliNotFoundError(configured);
  }
  const fromEnvironment = process.env.VESALIUS_CLI_PATH?.trim();
  if (fromEnvironment && isExecutable(expandHome(fromEnvironment))) {
    return locationFor(expandHome(fromEnvironment), 'VESALIUS_CLI_PATH');
  }
  for (const directory of (process.env.PATH ?? '').split(path.delimiter)) {
    if (directory && isExecutable(path.join(directory, 'vesalius'))) {
      return locationFor(path.join(directory, 'vesalius'), 'PATH');
    }
  }
  const wellKnown = [path.join(os.homedir(), '.local/bin/vesalius'), '/usr/local/bin/vesalius', '/opt/homebrew/bin/vesalius'];
  for (const candidate of wellKnown) {
    if (isExecutable(candidate)) {
      return locationFor(candidate, candidate);
    }
  }
  for (const candidate of appBinaries) {
    if (isExecutable(candidate)) {
      return locationFor(candidate, 'Vesalius.app');
    }
  }
  for (const folder of folders) {
    for (const configuration of ['release', 'debug']) {
      const candidate = path.join(folder.uri.fsPath, 'VesaliusKit', '.build', configuration, 'vesalius');
      if (isExecutable(candidate)) {
        return locationFor(candidate, `development build (${configuration})`);
      }
    }
  }
  throw new CliNotFoundError();
}

/** The installed Vesalius app binary, if any (used for "Open in Vesalius App" and CLI installation). */
export function findAppBinary(): string | undefined {
  return appBinaries.find(isExecutable);
}

export interface RunOptions {
  cwd: string;
  timeoutMs: number;
  token?: vscode.CancellationToken;
}

/** Runs the CLI and parses its JSON output. */
export class VesaliusCli {
  constructor(
    readonly location: CliLocation,
    private readonly log: vscode.OutputChannel,
  ) {}

  run<T>(args: string[], options: RunOptions): Promise<T> {
    const fullArgs = [...this.location.prefixArgs, ...args];
    const started = Date.now();
    this.log.appendLine(`$ vesalius ${args.map(quoteForLog).join(' ')}`);
    return new Promise<T>((resolve, reject) => {
      if (options.token?.isCancellationRequested) {
        reject(new vscode.CancellationError());
        return;
      }
      const child = spawn(this.location.command, fullArgs, { cwd: options.cwd, env: process.env });
      const stdout: Buffer[] = [];
      const stderr: Buffer[] = [];
      let settled = false;
      const finish = (error: unknown, value?: T) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        subscription?.dispose();
        if (error) {
          reject(error);
        } else {
          resolve(value as T);
        }
      };
      const timer = setTimeout(() => {
        child.kill('SIGTERM');
        finish(new CliError(`Vesalius did not answer within ${Math.round(options.timeoutMs / 1000)} seconds (vesalius ${args[0]}).`));
      }, options.timeoutMs);
      const subscription = options.token?.onCancellationRequested(() => {
        child.kill('SIGTERM');
        finish(new vscode.CancellationError());
      });
      child.stdout.on('data', (chunk: Buffer) => stdout.push(chunk));
      child.stderr.on('data', (chunk: Buffer) => stderr.push(chunk));
      child.on('error', (error) => finish(new CliError(`Could not run ${this.location.command}: ${error.message}`)));
      child.on('close', (code) => {
        const out = Buffer.concat(stdout).toString('utf8').trim();
        const err = Buffer.concat(stderr).toString('utf8').trim();
        const elapsed = Date.now() - started;
        if (code === 0) {
          try {
            this.log.appendLine(`  ok in ${elapsed} ms (${out.length} bytes)`);
            finish(undefined, (out ? JSON.parse(out) : undefined) as T);
          } catch (error) {
            finish(new CliError(`Vesalius returned output that is not JSON: ${out.slice(0, 200)}`, [], code, err));
          }
          return;
        }
        let message = err || `vesalius exited with status ${code}`;
        let suggestions: string[] = [];
        try {
          const parsed = JSON.parse(out) as { error?: string; suggestions?: string[] };
          if (parsed.error) {
            message = parsed.error;
            suggestions = parsed.suggestions ?? [];
          }
        } catch {
          // Not JSON: keep stderr.
        }
        this.log.appendLine(`  failed in ${elapsed} ms: ${message}`);
        finish(new CliError(message, suggestions, code, err));
      });
    });
  }
}

function quoteForLog(arg: string): string {
  return /^[\w./:@=-]+$/.test(arg) ? arg : JSON.stringify(arg);
}
