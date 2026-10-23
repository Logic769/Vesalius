import { execFileSync, spawn } from 'child_process';
import * as assert from 'assert';
import * as path from 'path';
import * as vscode from 'vscode';
import type { VesaliusApi } from '../../extension';

export const extensionID = 'vesalius.vesalius';

export async function activateExtension(): Promise<VesaliusApi> {
  const extension = vscode.extensions.getExtension<VesaliusApi>(extensionID);
  assert.ok(extension, `${extensionID} is loaded in the test instance`);
  const api = await extension.activate();
  await api.ready;
  return api;
}

export function workspaceFolder(): vscode.Uri {
  const folder = vscode.workspace.workspaceFolders?.[0];
  assert.ok(folder, 'a workspace folder is open');
  return folder.uri;
}

export function fileUri(relativePath: string): vscode.Uri {
  return vscode.Uri.joinPath(workspaceFolder(), ...relativePath.split('/'));
}

/** Polls until `probe` returns something truthy. */
export async function waitFor<T>(description: string, probe: () => T | undefined | false | Promise<T | undefined | false>, timeoutMs = 30_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await probe();
    if (value) {
      return value;
    }
    if (Date.now() > deadline) {
      throw new Error(`Timed out after ${timeoutMs} ms waiting for ${description}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
}

export function vesaliusDiagnostics(uri: vscode.Uri): vscode.Diagnostic[] {
  return vscode.languages.getDiagnostics(uri).filter((diagnostic) => diagnostic.source === 'Vesalius');
}

export interface McpExchange {
  serverName: string;
  tools: string[];
  call?: string;
}

/**
 * Starts an MCP server exactly as a client would from a config (command, args, env), performs the
 * initialize handshake, lists tools and optionally calls one. Resolves with what the server said.
 */
export function mcpHandshake(command: string, args: string[], env: Record<string, string>, call?: { name: string; arguments: Record<string, unknown> }): Promise<McpExchange> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { env: { ...process.env, ...env }, stdio: ['pipe', 'pipe', 'pipe'] });
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error('MCP server did not answer within 60 s'));
    }, 60_000);
    const result: McpExchange = { serverName: '', tools: [] };
    let buffer = '';
    const send = (message: unknown) => child.stdin.write(`${JSON.stringify(message)}\n`);
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk: string) => {
      buffer += chunk;
      let newline = buffer.indexOf('\n');
      while (newline >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        newline = buffer.indexOf('\n');
        if (!line) {
          continue;
        }
        const message = JSON.parse(line) as { id?: number; result?: any; error?: { message: string } };
        if (message.error) {
          clearTimeout(timer);
          child.kill();
          reject(new Error(`MCP error: ${message.error.message}`));
          return;
        }
        if (message.id === 1) {
          result.serverName = message.result?.serverInfo?.name ?? '';
          send({ jsonrpc: '2.0', method: 'notifications/initialized' });
          send({ jsonrpc: '2.0', id: 2, method: 'tools/list' });
        } else if (message.id === 2) {
          result.tools = (message.result?.tools ?? []).map((tool: { name: string }) => tool.name);
          if (call) {
            send({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: call });
          } else {
            finish();
          }
        } else if (message.id === 3) {
          result.call = (message.result?.content ?? []).map((part: { text?: string }) => part.text ?? '').join('\n');
          finish();
        }
      }
    });
    const finish = () => {
      clearTimeout(timer);
      child.stdin.end();
      child.kill();
      resolve(result);
    };
    child.on('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
    send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'vesalius-vscode-tests', version: '1.0.0' } } });
  });
}

/**
 * Saves a PNG of this VS Code window to $VESALIUS_TEST_SCREENSHOTS (macOS only). A no-op unless that
 * variable is set: used to review the UI the tests drive, not to assert anything.
 */
export async function screenshot(name: string): Promise<void> {
  const directory = process.env.VESALIUS_TEST_SCREENSHOTS;
  if (!directory || process.platform !== 'darwin') {
    return;
  }
  await new Promise((resolve) => setTimeout(resolve, 900));
  // The extension host's parent is the VS Code main process, which owns the window.
  const script = `ObjC.import('CoreGraphics');
var all = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, $.kCGNullWindowID)));
var mine = all.filter(function (w) { return w.kCGWindowOwnerPID == ${process.ppid} && w.kCGWindowLayer == 0; });
mine.sort(function (a, b) { return b.kCGWindowBounds.Width * b.kCGWindowBounds.Height - a.kCGWindowBounds.Width * a.kCGWindowBounds.Height; });
mine.length ? String(mine[0].kCGWindowNumber) : '';`;
  try {
    const id = execFileSync('osascript', ['-l', 'JavaScript', '-e', script], { encoding: 'utf8' }).trim();
    if (id) {
      execFileSync('screencapture', ['-x', '-o', `-l${id}`, path.join(directory, `${name}.png`)]);
    }
  } catch (error) {
    console.log(`      (screenshot ${name} failed: ${error instanceof Error ? error.message : String(error)})`);
  }
}
