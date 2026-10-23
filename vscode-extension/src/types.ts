// JSON shapes produced by `vesalius … --json`. Optional fields are omitted by the CLI when empty.

/** Inclusive 1-based line range, serialised as "12-48" or "12". */
export type LineRangeText = string;

export type SymbolKind =
  | 'class' | 'struct' | 'enum' | 'protocol' | 'interface' | 'actor' | 'extension' | 'typealias'
  | 'function' | 'method' | 'initializer' | 'property' | 'variable' | 'constant' | 'case'
  | 'namespace' | 'macro' | 'component';

export type Severity = 'info' | 'low' | 'medium' | 'high' | 'critical';
export type RiskLevel = 'low' | 'moderate' | 'high' | 'critical';

export interface IndexSummary {
  repository: string;
  indexPath: string;
  filesScanned: number;
  filesAdded: number;
  filesChanged: number;
  filesRemoved: number;
  filesUnchanged: number;
  filesFailed: number;
  symbols: number;
  references: number;
  edges: number;
  durationSeconds: number;
  warnings: string[];
  analysisUpdated?: boolean;
}

export interface RepositoryStatus {
  repository: { name: string; path: string; isGitRepository: boolean; branch?: string; headCommit?: string };
  indexPath: string;
  isIndexed: boolean;
  lastIndexed?: string;
  stats: { files: number; sourceFiles: number; symbols: number; dependencies: number };
}

export interface AskSymbol {
  name: string;
  kind: SymbolKind;
  lines: LineRangeText;
}

export interface AskFile {
  path: string;
  relevance: number;
  reason: string;
  symbols: AskSymbol[];
  lines?: LineRangeText;
  dependents?: number;
  dependencies?: number;
}

export interface RelatedFile {
  path: string;
  score: number;
  reason: string;
}

export interface AskResult {
  query: string;
  intent: string;
  answer: string;
  terms: string[];
  files: AskFile[];
  related?: RelatedFile[];
  confidence: number;
}

export interface SymbolSummary {
  id: string;
  name: string;
  qualifiedName: string;
  kind: SymbolKind;
  path: string;
  lines: LineRangeText;
  signature?: string;
  doc?: string;
  visibility?: string;
  isExported?: boolean;
  references?: number;
  depth?: number;
}

export interface SymbolHit {
  symbol: SymbolSummary;
  score: number;
}

export interface FileRelation {
  path: string;
  kinds: string[];
  weight: number;
  symbols?: string[];
  distance?: number;
}

export interface ReferenceSite {
  path: string;
  line: number;
  kind: string;
  from?: string;
  snippet?: string;
  count?: number;
}

export interface ReferencesResult {
  query: string;
  symbols: SymbolSummary[];
  references: ReferenceSite[];
  total: number;
  textualMatches?: ReferenceSite[];
}

export interface CallRelation {
  symbol: SymbolSummary;
  sites: number[];
  count: number;
}

export interface CallGraphResult {
  query: string;
  direction: string;
  symbols: SymbolSummary[];
  relations: CallRelation[];
}

export interface DependencyResult {
  target: string;
  direction: string;
  depth: number;
  files: FileRelation[];
  externalModules?: string[];
  total: number;
}

export interface ScoreFactor {
  label: string;
  detail: string;
  impact: number;
  value?: number;
}

export interface ImpactSummary {
  directDependents: number;
  transitiveDependents: number;
  relatedTests: number;
  riskScore: number;
  riskLevel: RiskLevel;
}

export interface ImpactReport {
  target: string;
  targetKind: string;
  symbols?: SymbolSummary[];
  directDependents: FileRelation[];
  transitiveDependents: FileRelation[];
  callers: ReferenceSite[];
  relatedTests: string[];
  affectedAreas: { name: string; files: number }[];
  riskScore: number;
  riskLevel: RiskLevel;
  factors: ScoreFactor[];
  summary: string;
}

export interface DiagnosticTarget {
  kind: 'file' | 'symbol' | 'directory' | 'module';
  path: string;
  symbol?: string;
  line?: number;
}

export interface DiagnosticMetric {
  name: string;
  value: number;
  threshold?: number;
  unit?: string;
}

export interface Diagnostic {
  id: string;
  rule: string;
  category: string;
  severity: Severity;
  title: string;
  summary: string;
  reason: string;
  recommendation: string;
  targets: DiagnosticTarget[];
  metrics: DiagnosticMetric[];
}

export interface FileSummary {
  path: string;
  language: string;
  size: number;
  lines: number;
  codeLines: number;
  symbols: number;
  complexity: number;
  fanIn: number;
  fanOut: number;
  centrality: number;
  risk: number;
  churn?: number;
  diagnostics: number;
  isTest: boolean;
  isGenerated: boolean;
  module?: string;
}

export interface FileGraphMetrics {
  fanIn: number;
  fanOut: number;
  centrality: number;
  transitiveDependents: number;
  transitiveDependencies: number;
  depth: number;
  cycleID?: number;
  cycleSize?: number;
  churn?: number;
  risk: number;
}

export interface ImportSummary {
  module: string;
  line: number;
  resolvedPath?: string;
  isExternal: boolean;
  names?: string[];
}

export interface FileContext {
  file: FileSummary;
  symbols: SymbolSummary[];
  imports: ImportSummary[];
  dependencies: FileRelation[];
  dependents: FileRelation[];
  metrics: FileGraphMetrics;
  diagnostics: Diagnostic[];
  related: RelatedFile[];
  impact: ImpactSummary;
}

export interface CategoryScore {
  category: string;
  score: number;
  weight: number;
  summary: string;
  factors: ScoreFactor[];
}

export interface HealthReport {
  score: number;
  grade: string;
  summary: string;
  categories: CategoryScore[];
  diagnosticCounts: Record<string, number>;
}

export interface HealthResult {
  health: HealthReport;
  diagnostics: Diagnostic[];
}

export interface Hotspot {
  path: string;
  score: number;
  lines: number;
  complexity: number;
  fanIn: number;
  fanOut: number;
  churn?: number;
  diagnostics: number;
  reasons: string[];
}

export const severityOrder: Severity[] = ['info', 'low', 'medium', 'high', 'critical'];

export const categoryTitles: Record<string, string> = {
  modularity: 'Modularity',
  coupling: 'Coupling',
  complexity: 'Complexity',
  cycles: 'Cycles',
  organization: 'File Organization',
  boundaries: 'Dependency Boundaries',
  maintainability: 'Maintainability',
  'dead-code': 'Dead Code Signals',
};

/** Parses "12-48" (or "12") into 1-based start and end lines. */
export function parseLines(text: LineRangeText | undefined): { start: number; end: number } | undefined {
  if (!text) {
    return undefined;
  }
  const [start, end] = text.split('-').map((part) => Number.parseInt(part, 10));
  if (!Number.isFinite(start)) {
    return undefined;
  }
  return { start, end: Number.isFinite(end) ? end : start };
}
