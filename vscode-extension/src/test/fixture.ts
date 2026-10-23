import { execFileSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

/**
 * A small TypeScript + Python repository with known anatomy:
 * - src/api/client.ts is used by src/api/users.ts, which is used by src/ui/UserCard.tsx
 * - src/cycle/a.ts and src/cycle/b.ts import each other (a dependency cycle)
 * - src/legacy/bigReport.ts is a large file (120 functions)
 * - src/billing/invoice.ts is where invoice totals are calculated
 */
export const fixtureFiles: Record<string, string> = {
  'src/api/client.ts': `/** Minimal HTTP client used by every API module. */
export class ApiClient {
  constructor(private readonly base: string) {}
  get(path: string): Promise<Response> {
    return fetch(this.base + path);
  }
}
`,
  'src/api/users.ts': `import { ApiClient } from './client';

export function fetchUser(id: number) {
  const client = new ApiClient('https://example.com');
  return client.get(\`/users/\${id}\`);
}
`,
  'src/ui/UserCard.tsx': `import { fetchUser } from '../api/users';

export function UserCard({ id }: { id: number }) {
  fetchUser(id);
  return <div>user</div>;
}
`,
  'src/cycle/a.ts': `import { b } from './b';
export const a = (n: number): number => (n > 0 ? b(n - 1) : 0);
`,
  'src/cycle/b.ts': `import { a } from './a';
export const b = (n: number): number => (n > 0 ? a(n - 1) : 1);
`,
  'src/billing/invoice.ts': `export interface InvoiceLine { quantity: number; unitPrice: number; }

/** Calculates invoice totals including tax. */
export class InvoiceCalculator {
  constructor(private readonly taxRate: number) {}
  subtotal(lines: InvoiceLine[]): number {
    return lines.reduce((sum, line) => sum + line.quantity * line.unitPrice, 0);
  }
  total(lines: InvoiceLine[]): number {
    return this.subtotal(lines) * (1 + this.taxRate);
  }
}

export function calculateInvoiceTotal(lines: InvoiceLine[]): number {
  return new InvoiceCalculator(0.2).total(lines);
}
`,
  'src/billing/checkout.ts': `import { calculateInvoiceTotal, InvoiceLine } from './invoice';

export function checkout(lines: InvoiceLine[]): string {
  return \`Total: \${calculateInvoiceTotal(lines).toFixed(2)}\`;
}
`,
  'src/legacy/bigReport.ts': bigReport(),
  'py/app/__init__.py': '',
  'py/app/models.py': `class User:
    """A registered user."""

    def __init__(self, name):
        self.name = name
`,
  'py/app/service.py': `from .models import User


def load_user(name):
    return User(name)
`,
  'py/tests/test_service.py': `from app.service import load_user


def test_load_user():
    assert load_user("ada").name == "ada"
`,
};

function bigReport(): string {
  const lines = ['// Report helpers kept in one large file.'];
  for (let i = 0; i < 120; i += 1) {
    lines.push(
      `export function reportSection${i}(rows: number[]): number {`,
      `  const total = rows.reduce((a, b) => a + b, ${i});`,
      `  return total > ${i} ? total : ${i};`,
      '}',
    );
  }
  return `${lines.join('\n')}\n`;
}

/** Writes the fixture into `root` and commits it to a fresh git repository (when git is available). */
export function createFixture(root: string): string {
  for (const [relative, content] of Object.entries(fixtureFiles)) {
    const file = path.join(root, ...relative.split('/'));
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, content);
  }
  try {
    const git = (...args: string[]) => execFileSync('git', ['-c', 'user.name=Vesalius Tests', '-c', 'user.email=tests@vesalius.invalid', ...args], { cwd: root, stdio: 'ignore' });
    git('init', '-q');
    git('add', '-A');
    git('commit', '-q', '-m', 'Fixture');
  } catch {
    // Not a git repository then; Vesalius indexes plain folders too.
  }
  return root;
}
