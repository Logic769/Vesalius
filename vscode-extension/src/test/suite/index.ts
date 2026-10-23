import * as path from 'path';
import Mocha from 'mocha';

/** Entry point VS Code calls inside the extension host. Picks the suite from VESALIUS_TEST_SUITE. */
export function run(): Promise<void> {
  const mocha = new Mocha({ ui: 'tdd', color: true, timeout: 120_000, slow: 5_000 });
  const suites: Record<string, string> = { fixture: 'fixture.test.js', real: 'realRepository.test.js', missing: 'missingCli.test.js' };
  const suite = suites[process.env.VESALIUS_TEST_SUITE ?? 'fixture'] ?? suites.fixture;
  mocha.addFile(path.resolve(__dirname, suite));
  return new Promise((resolve, reject) => {
    mocha.run((failures) => (failures > 0 ? reject(new Error(`${failures} test${failures === 1 ? '' : 's'} failed.`)) : resolve()));
  });
}
