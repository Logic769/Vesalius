import { execFileSync } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { runTests } from '@vscode/test-electron';
import { createFixture } from './fixture';

/**
 * Runs the end-to-end suites in a real VS Code with the real `vesalius` CLI:
 * 1. "fixture": a generated TypeScript + Python repository with known anatomy.
 * 2. "missing": no CLI installed; recovery through the vesalius.cliPath setting.
 * 3. "real": an existing repository (VESALIUS_TEST_REPO), read only; skipped when unset.
 *
 * Indexes go to VESALIUS_HOME (a temporary directory unless set), never Application Support.
 */
async function main(): Promise<void> {
  const created: string[] = [];
  try {
    await runSuites(created);
  } finally {
    // Fixtures, VS Code profiles and any temporary index home are deleted after every run.
    for (const directory of created) {
      fs.rmSync(directory, { recursive: true, force: true });
    }
  }
}

async function runSuites(created: string[]): Promise<void> {
  // VESALIUS_TEST_EXTENSION_PATH runs the suites against another copy, such as an installed .vsix.
  const extensionDevelopmentPath = process.env.VESALIUS_TEST_EXTENSION_PATH || path.resolve(__dirname, '../../');
  const temp = fs.realpathSync(os.tmpdir());
  const tempDirectory = (prefix: string) => {
    const directory = fs.mkdtempSync(path.join(temp, prefix));
    created.push(directory);
    return directory;
  };
  const cli = findCli(path.resolve(__dirname, '../../'));
  const home = process.env.VESALIUS_HOME || tempDirectory('vesalius-home-');
  fs.mkdirSync(home, { recursive: true });
  const version = process.env.VSCODE_TEST_VERSION || 'stable';
  console.log(`extension: ${extensionDevelopmentPath}\nvesalius CLI: ${cli}\nVESALIUS_HOME: ${home}\nVS Code: ${version}`);

  const baseArgs = ['--disable-extensions', '--disable-workspace-trust', '--skip-welcome', '--skip-release-notes'];
  const environment = { VESALIUS_HOME: home, VESALIUS_CLI_PATH: cli };

  const fixture = createFixture(tempDirectory('vesalius-fixture-'));
  console.log(`\nFixture workspace: ${fixture}`);
  await runTests({
    version,
    extensionDevelopmentPath,
    extensionTestsPath: path.resolve(__dirname, './suite/index'),
    launchArgs: [fixture, ...baseArgs, `--user-data-dir=${tempDirectory('vesalius-user-')}`],
    extensionTestsEnv: { ...environment, VESALIUS_TEST_SUITE: 'fixture', VESALIUS_TEST_FIXTURE: fixture },
  });

  // Without a CLI: starts in the "not installed" state, then recovers through vesalius.cliPath.
  const preinstalled = wellKnownCliLocations().filter((file) => fs.existsSync(file));
  if (preinstalled.length > 0) {
    console.log(`\nSkipping the missing-CLI suite: a vesalius command is installed at ${preinstalled.join(', ')}.`);
  } else {
    const bare = createFixture(tempDirectory('vesalius-fixture-'));
    console.log(`\nMissing-CLI workspace: ${bare}`);
    await runTests({
      version,
      extensionDevelopmentPath,
      extensionTestsPath: path.resolve(__dirname, './suite/index'),
      launchArgs: [bare, ...baseArgs, `--user-data-dir=${tempDirectory('vesalius-user-')}`],
      extensionTestsEnv: { VESALIUS_HOME: home, VESALIUS_CLI_PATH: '', PATH: '/usr/bin:/bin:/usr/sbin:/sbin', VESALIUS_TEST_CLI: cli, VESALIUS_TEST_SUITE: 'missing' },
    });
  }

  const repository = process.env.VESALIUS_TEST_REPO;
  if (!repository) {
    console.log('\nVESALIUS_TEST_REPO is not set: skipping the real-repository suite.');
    return;
  }
  const root = fs.realpathSync(repository);
  console.log(`\nReal repository: ${root}`);
  const before = snapshot(root);
  await runTests({
    version,
    extensionDevelopmentPath,
    extensionTestsPath: path.resolve(__dirname, './suite/index'),
    launchArgs: [root, ...baseArgs, `--user-data-dir=${tempDirectory('vesalius-user-')}`],
    extensionTestsEnv: { ...environment, VESALIUS_TEST_SUITE: 'real', VESALIUS_TEST_REPO: root },
  });
  const after = snapshot(root);
  if (after !== before) {
    throw new Error(`The real repository changed during the tests.\nBefore:\n${before}\nAfter:\n${after}`);
  }
  console.log('Real repository unchanged by the tests (git status and .vscode identical).');
}

function findCli(extensionRoot: string): string {
  const candidates = [
    process.env.VESALIUS_CLI_PATH,
    path.resolve(extensionRoot, '../VesaliusKit/.build/debug/vesalius'),
    path.resolve(extensionRoot, '../VesaliusKit/.build/release/vesalius'),
  ].filter((candidate): candidate is string => Boolean(candidate));
  const found = candidates.find((candidate) => fs.existsSync(candidate));
  if (!found) {
    throw new Error(`No vesalius CLI found. Build it with "swift build --product vesalius --package-path VesaliusKit" or set VESALIUS_CLI_PATH. Looked in:\n${candidates.join('\n')}`);
  }
  return found;
}

/** Where the extension looks for an installed CLI (besides PATH and settings). */
function wellKnownCliLocations(): string[] {
  const home = os.homedir();
  return [
    path.join(home, '.local/bin/vesalius'),
    '/usr/local/bin/vesalius',
    '/opt/homebrew/bin/vesalius',
    '/Applications/Vesalius.app/Contents/MacOS/Vesalius',
    path.join(home, 'Applications/Vesalius.app/Contents/MacOS/Vesalius'),
  ];
}

/** What the tests must never change: git's view of the working tree, and the .vscode folder. */
function snapshot(root: string): string {
  let status = '(not a git repository)';
  try {
    status = execFileSync('git', ['status', '--porcelain=v1', '--untracked-files=all'], { cwd: root, encoding: 'utf8' });
  } catch {
    // Keep the placeholder.
  }
  const vscodeFolder = path.join(root, '.vscode');
  const settings = fs.existsSync(vscodeFolder) ? fs.readdirSync(vscodeFolder).sort().join(',') : '(no .vscode)';
  return `${status}\n${settings}`;
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
