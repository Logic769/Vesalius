#!/usr/bin/env python3
"""Golden checks for the Vesalius MCP v2 tools.

For each benchmark task it sends the planned call (plan.json) to the real `vesalius mcp` server over stdio,
against the benchmark repositories ($VESALIUS_BENCH_ROOT/<repo>, by default the folder holding this checkout; only
read), with a fresh VESALIUS_HOME per run.
The text that comes back is checked against private expectations derived from the answer keys:
  (a) no isError                       (e) every `must` item's anchors match (file, code, text, label)
  (b) plain text, no JSON or scores    (f) no forbidden anchor matches outside the footer labels
  (c) ceil(utf8 bytes / 3) <= budget   (g) the task's completeness line
  (d) every quoted code line matches   (h) warm p95 latency
      the file on disk                 (i) drift: a `code` anchor no longer in its file is STALE
It also checks the catalog (tools/list, instructions), the cold start (ping and tools/list answered while
the first call indexes) and the staleness scenario on a scratch fixture repository.

The expectations live outside this repository ($VESALIUS_GOLDEN_DIR/expectations.json). The harness refuses
expectation or run paths inside it, and prints only item ids and anchor kinds, never key content. Raw outputs
and results.json go to <golden dir>/runs/<timestamp>/.

How output text is read (the renderer contract):
- Leading `index: built just now (…)` / `re-indexed N files` notes are set aside; then line 1 is the header and
  line 2 holds the totals and `complete`/`INCOMPLETE`.
- A file context starts at the first repo path on a line (repo-relative, or a unique path suffix). A line
  starting with `declaring file` refers to the header's path.
- Line numbers: `NNN │ code`, `·NNN`, `:NNN`, `path:NNN`, comma lists `468,471,482`, `A-B ×N`; a range covers
  its interior only when it spans at most 6 lines or carries `×N`. Bare numbers on lines 3+ count weakly
  (required items only, never forbidden ones).
- Code is the text after `│ ` (its line is the `NNN` right before the bar, else the last `:NNN` before it), or
  after a `:NNN ` that starts a line or follows `→`/`←`; it ends at two spaces, ` ·NNN`, ` · ` or an arrow, and a
  trailing label such as `[sink]` is dropped. With whitespace removed, its `…`-separated pieces must appear in
  order in lines NNN..NNN+2 of the file.
- Excluded material sits after a label on the same line (`not code uses:`, `rejected lookalikes:`,
  `transitive only`, `mock only`, `also named`, `TEXT ONLY`, `NOT AFFECTED`, `not this feature:`, `not built:`,
  `more:`, `called by:`, `unresolved:`), after `complete`/`INCOMPLETE` on line 2, or on a line labelled
  `[mock only]`/`[not built]`. Forbidden anchors ignore it; required ones see it only when they ask (`in`).

Usage:
  golden_check.py [--vesalius <binary>] [--gate G1|G2|G3|all | --tasks B3,C1] [--only catalog,cold,stale,tasks]
                  [--repeat 1] [--warm 3] [--expect-loaded auto|none|usages,...] [--always-load <list>]
                  [--expectations <file>] [--runs-dir <dir>] [--keep-home]
  golden_check.py --validate-expectations [--expectations <file>]
  golden_check.py --check-text <file> --task B3     (offline: assertions (b)-(g) on saved tool text)
Exit status: 0 iff the selected gate (default all), tasks or checks pass.
"""
import argparse, hashlib, json, math, os, posixpath, re, shutil, subprocess, sys, time
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.realpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.dirname(HERE))
sys.dont_write_bytecode = True  # no __pycache__ inside the repository
import mcp_client  # noqa: E402

PLAN_PATH = os.path.join(HERE, "plan.json")
TASKS_PATH = os.path.join(os.path.dirname(HERE), "tasks.json")
# Where the benchmark repositories live; point it at frozen copies to gate against a tree nobody is editing.
BENCH_ROOT = os.environ.get("VESALIUS_BENCH_ROOT") or os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
SKIP_DIRS = {".git", ".build", "build", "DerivedData", "node_modules", ".next", "Pods", ".swiftpm", "dist",
             "coverage", "__pycache__", ".venv", "xcuserdata"}
LABELS = ("not code uses:", "rejected lookalikes:", "transitive only", "mock only", "also named", "TEXT ONLY",
          "NOT AFFECTED", "not this feature:", "not built:", "more:", "called by:", "unresolved:", "UNRESOLVED")
# Whole lines the tool itself marks as not a use: mocks, files outside every build, and compile-coupled tests
# (they reference the owner type, and the line says none of them uses the target).
LINE_LABELS = ("[mock only]", "[not built]", "; none use the target)")
NOTE = re.compile(r"^(index: built just now \(|re-indexed \d+ files?\b)")
EXT = (r"swift|tsx?|jsx?|mjs|cjs|py|md|json|plist|pbxproj|storekit|xctestplan|xcscheme|entitlements|sh|ya?ml|toml|"
       r"css|html|sql|metal|h|m|mm|c|cpp|resolved|txt|strings|xcstrings|xcconfig|gitmodules")
PATH_END = re.compile(r"\.(?:" + EXT + r")(?![A-Za-z0-9_])")
NOT_IN_PATH = set("│·→←↔…|:\"'`<>\t")
DELIMS = set(" ([{,;=*") | NOT_IN_PATH
NUMS = r"\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*"
PATH_LINES = re.compile(r":(" + NUMS + r")(?![\w.])")
COUNT_WORDS = (r"(?:files?|uses?|callers?|calls?|sites?|refs?|references?|lines?|tests?|more|of|tokens?|edges?|"
               r"occurrences?|members?|targets?|packages?|products?|views?|services?|models?|folders?|modules?|"
               r"imports?|importers?|dependents?|cycles?|unresolved|ms|s|KB|MB|chars?|bytes?|swift)")
TOKEN = re.compile(
    r"(?P<code>(?<![\w.×+~#$-])\d+)[ \t]*│"
    r"|·(?P<dot>" + NUMS + r")"
    r"|(?<![\w.:/]):(?P<colon>" + NUMS + r")(?![\w.])"
    r"|(?<![\w.:/·×+~#$-])(?P<range>\d+-\d+)[ \t]*×\d+"
    r"|(?<![\w.:/·×+~#$-])(?P<list>\d+(?:-\d+)?(?:,\d+(?:-\d+)?)+)(?![\w.])"
    r"|(?<![\w.:/·×+~#$-])(?P<bare>\d+)(?![\w.,:%-])(?!\s+" + COUNT_WORDS + r"\b)"
    r"|(?<!\w)L(?P<ell>\d+)\b")
CODE_LINE = re.compile(r"(?<![\w.×+~#$-])(\d+)[ \t]*│ ?")
COLON_CODE = re.compile(r"(?:^[ \t]*|[→←][ \t])(:(\d+) )(?=[^\s(\[·—–×+,\"'-])")
CODE_END = re.compile(r"\s{2,}| ·(?=\d)| [→←] | · ")
TRAILING_LABEL = re.compile(r"\s+\[(?:sink|test|#if|type-inferred|via |not built|mock only|reads|writes|external|implicit|unresolved|ui|unit)[^\[\]]*\]\s*$")
SCORE_WORDS = re.compile(r"\b(confidence|risk|centrality|relevance|weight)\b", re.I)
COVER_SPAN = 6


def squash(s):
    return re.sub(r"\s+", "", s)


def without_notes(text):
    lines = text.split("\n")
    while lines and NOTE.match(lines[0]):
        lines.pop(0)
    return lines


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


def outside_repo(path, what):
    real = os.path.realpath(path)
    if real == REPO_ROOT or real.startswith(REPO_ROOT + os.sep):
        sys.exit(f"golden_check: refusing {what} inside the repository ({path}); key-derived data stays outside {REPO_ROOT}")
    return path


def load_json(path):
    with open(path) as f:
        return json.load(f)


# MARK: - Repository files (read only)

class RepoIndex:
    """Files of one benchmark repository: the path set, a suffix index and cached file lines."""

    def __init__(self, root):
        self.root, self.paths, self.by_suffix, self._lines = root, set(), defaultdict(list), {}
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            rel = os.path.relpath(dirpath, root)
            for name in filenames:
                self.paths.add(name if rel == "." else f"{rel}/{name}")
        for path in self.paths:
            parts = path.split("/")
            for i in range(len(parts)):
                self.by_suffix["/".join(parts[i:])].append(path)

    def lines(self, path):
        if path not in self._lines:
            full = os.path.join(self.root, path)
            if not os.path.isfile(full):
                self._lines[path] = None
            else:
                with open(full, "rb") as f:
                    self._lines[path] = [l.rstrip("\r") for l in f.read().decode("utf-8", "replace").split("\n")]
        return self._lines[path]

    def resolve(self, token, near=None):
        token = token.strip()
        token = token[2:] if token.startswith("./") else token.lstrip("/")
        if not token:
            return None
        if token in self.paths:
            return token
        if near:
            joined = posixpath.normpath(posixpath.join(posixpath.dirname(near), token))
            if joined in self.paths:
                return joined
        hits = self.by_suffix.get(token)
        return hits[0] if hits and len(hits) == 1 else None

    def find_code(self, anchor):
        """Resolves a `code` anchor to its current line: (line, candidates, problem). `after` is a fragment, or a
        chain of fragments each found from the previous one, that the code must follow (e.g. its function)."""
        lines = self.lines(anchor["path"])
        if lines is None:
            return None, 0, "file missing"
        start = 0
        after = anchor.get("after")
        for step in ([after] if isinstance(after, str) else after or []):
            step = norm(step)
            start = next((i for i in range(start, len(lines)) if step in norm(lines[i])), None)
            if start is None:
                return None, 0, "`after` fragment not found"
        fragment = norm(anchor["code"])
        hits = [i + 1 for i in range(start, len(lines)) if fragment in norm(lines[i])]
        if not hits:
            return None, 0, "fragment not found"
        if anchor.get("after"):
            nth = anchor.get("nth", 1)
            return (hits[nth - 1], len(hits), None) if nth <= len(hits) else (None, len(hits), "nth beyond matches")
        hint = anchor.get("line", hits[0])
        return min(hits, key=lambda h: (abs(h - hint), h)), len(hits), None

    def drift(self):
        """HEAD and a hash of `git status --porcelain`, read without taking optional locks."""
        def git(*a):
            r = subprocess.run(["git", "--no-optional-locks", "-C", self.root, *a], capture_output=True, text=True)
            return r.stdout if r.returncode == 0 else ""
        porcelain = git("status", "--porcelain")
        return {"head": git("rev-parse", "--short", "HEAD").strip() or None,
                "dirty": len([l for l in porcelain.splitlines() if l.strip()]),
                "porcelain_sha": hashlib.sha256(porcelain.encode()).hexdigest()[:12]}


# MARK: - Reading tool output

class Mention:
    __slots__ = ("file", "line", "strong", "exempt", "label", "n")

    def __init__(self, file, line, strong, exempt, label, n):
        self.file, self.line, self.strong, self.exempt, self.label, self.n = file, line, strong, exempt, label, n


def expand(spec):
    """'53,55,148-153,171' -> [(line, strong)]: endpoints strong, short-range interiors weak."""
    out = []
    for part in spec.split(","):
        if "-" in part:
            a, b = (int(x) for x in part.split("-", 1))
            out += [(a, True), (b, True)]
            if 0 < b - a <= COVER_SPAN:
                out += [(x, False) for x in range(a + 1, b)]
        else:
            out.append((int(part), True))
    return out


class Output:
    """One tool result parsed into lines, file contexts, line mentions, quoted code and exempt segments."""

    def __init__(self, text, ix):
        self.ix, self.raw = ix, text
        lines = text.split("\n")
        self.notes = []
        while lines and NOTE.match(lines[0]):
            self.notes.append(lines.pop(0))
        self.lines = lines
        self.mentions, self.paths, self.code = [], [], []
        self.exempt_from, self.owner = [], []
        self.blocks, self.heads = defaultdict(list), defaultdict(set)
        self.header_path = None
        ctx = None
        for n, line in enumerate(lines, 1):
            ctx = self._parse_line(n, line, ctx)

    def _code_spans(self, line):
        spans = []
        m = CODE_LINE.search(line)
        if m:
            end = CODE_END.search(line, m.end())
            spans.append((m.end(), end.start() if end else len(line), int(m.group(1)), m.start(1)))
        elif "│" in line:
            bar = line.index("│")
            nums = list(re.finditer(r":(\d+)(?![\d-])", line[:bar]))
            if nums:
                start = bar + 1 + (line[bar + 1:bar + 2] == " ")
                end = CODE_END.search(line, start)
                spans.append((start, end.start() if end else len(line), int(nums[-1].group(1)), nums[-1].start(1)))
        for m in COLON_CODE.finditer(line):
            if spans and spans[0][0] <= m.start(1) < spans[0][1]:
                continue
            end = CODE_END.search(line, m.end(1))
            spans.append((m.end(1), end.start() if end else len(line), int(m.group(2)), m.start(1)))
        return spans

    def _parse_line(self, n, line, ctx):
        spans = self._code_spans(line)
        blank = [False] * len(line)
        for s, e, _, _ in spans:
            for i in range(s, e):
                blank[i] = True
        visible = "".join(" " if blank[i] else ch for i, ch in enumerate(line))
        exempt_from, label = len(line), None
        if n == 2:
            m = re.search(r"\bcomplete\b|\bINCOMPLETE\b", visible)
            if m:
                exempt_from, label = m.start(), "complete"
        for name in LABELS:
            i = visible.find(name)
            if 0 <= i < exempt_from:
                exempt_from, label = i, name
        whole_line = next((name for name in LINE_LABELS if name in visible), None)
        if whole_line:
            exempt_from, label = 0, whole_line
        self.exempt_from.append((exempt_from, label))

        # Paths, longest first from the left, each with its own `:NNN` list.
        found, last_end = [], 0
        for m in PATH_END.finditer(line):
            e = m.end()
            if blank[e - 1]:
                continue
            for s in range(last_end, m.start()):
                if (s > 0 and line[s - 1] not in DELIMS) or line[s] in " \t":
                    continue
                fragment = line[s:e]
                if any(ch in NOT_IN_PATH for ch in fragment):
                    continue
                path = self.ix.resolve(fragment, found[-1][2] if found else ctx)
                if path:
                    tail = PATH_LINES.match(line, e)
                    found.append((s, tail.end() if tail else e, path, tail.group(1) if tail else None))
                    last_end = tail.end() if tail else e
                    break
        for s, e, _, _ in found:
            for i in range(s, e):
                blank[i] = True
        site = [p for p in found if p[0] < exempt_from or whole_line]
        line_owner = site[0][2] if site else ctx
        if line.strip().startswith("declaring file") and self.header_path:
            line_owner = self.header_path
        if n == 1 and found:
            self.header_path = found[0][2]

        def owner_at(pos):
            before = [p for p in found if p[0] < pos]
            return before[-1][2] if before else (line_owner if not site else ctx)

        indent = len(line) - len(line.lstrip())
        for s, e, path, spec in found:
            exempt = s >= exempt_from
            block = n >= 3 and not exempt and s == indent and site and site[0][0] == s
            self.paths.append((n, path, exempt, label if exempt else None, block))
            if spec:
                for num, strong in expand(spec):
                    self.mentions.append(Mention(path, num, strong, exempt, label if exempt else None, n))
        if site and site[0][0] == indent and n >= 3:
            self.heads[site[0][2]].add(n)
        elif self.owner and self.owner[-1] and self.owner[-1] == line_owner and (n - 1) in self.heads[line_owner] \
                and not found and "│" not in line:
            self.heads[line_owner].add(n)

        masked = "".join(" " if blank[i] else ch for i, ch in enumerate(line))
        for m in TOKEN.finditer(masked):
            kind = m.lastgroup
            if kind in ("bare", "ell") and n < 3:
                continue
            exempt = m.start() >= exempt_from
            file = owner_at(m.start())
            if not file:
                continue
            spec = m.group(kind)
            values = expand(spec) if kind in ("dot", "colon", "list", "range") else [(int(spec), kind == "code")]
            if kind == "range":
                lo, hi = (int(x) for x in spec.split("-"))
                values = [(lo, True), (hi, True)] + [(x, False) for x in range(lo + 1, hi)]
            for num, strong in values:
                self.mentions.append(Mention(file, num, strong and kind not in ("bare", "ell"), exempt,
                                             label if exempt else None, n))

        for s, e, num, num_pos in spans:
            file = owner_at(num_pos)
            self.code.append({"n": n, "file": file, "line": num, "code": line[s:e].strip()})

        self.owner.append(line_owner)
        if line_owner:
            self.blocks[line_owner].append(n)
        return line_owner if site or line.strip().startswith("declaring file") else ctx

    # MARK: segments

    def segment_ok(self, exempt, label, where):
        if where == "any":
            return True
        if where == "site":
            return not exempt
        return exempt and label == where

    def texts(self, where="any", file=None, line=None, mask_code=False):
        lines = {line} if isinstance(line, int) else set(line or ())
        for n, text in enumerate(self.lines, 1):
            if lines and n not in lines:
                continue
            if file and self.owner[n - 1] != file:
                continue
            if mask_code:
                for c in self.code:
                    if c["n"] == n and c["code"]:
                        text = text.replace(c["code"], " " * len(c["code"]))
            start, label = self.exempt_from[n - 1]
            if where == "any":
                yield n, text
            elif where == "site":
                yield n, text[:start]
            elif label == where:
                yield n, text[start:]

    def mentioned(self, file, num, where="site", strong=False, slack=0):
        return [m.n for m in self.mentions if m.file == file and abs(m.line - num) <= slack
                and (m.strong or not strong) and self.segment_ok(m.exempt, m.label, where)]

    # MARK: evidence fidelity (d)

    def check_fidelity(self):
        """Returns the quoted code lines that do not match the file on disk; adds matched spans as weak mentions."""
        bad = []
        for c in self.code:
            lines = self.ix.lines(c["file"]) if c["file"] else None
            if not squash(c["code"].replace("…", "")):
                continue
            if lines is None:
                bad.append({**c, "why": "no file context" if not c["file"] else "file missing"})
                continue
            window = lines[c["line"] - 1:c["line"] + 2] if c["line"] >= 1 else []
            joined, ends = "", []
            for l in window:
                joined += squash(l)
                ends.append(len(joined))
            code, pos = c["code"], -1
            for _ in range(3):
                pos = 0
                for p in [squash(p) for p in code.split("…") if squash(p)]:
                    i = joined.find(p, pos)
                    if i < 0:
                        pos = -1
                        break
                    pos = i + len(p)
                stripped = TRAILING_LABEL.sub("", code)
                if pos >= 0 or stripped == code:
                    break
                code = stripped
            if pos < 0:
                bad.append({**c, "why": "not in lines %d-%d" % (c["line"], c["line"] + 2)})
                continue
            last = c["line"] + next(k for k, e in enumerate(ends) if e >= pos)
            for num in range(c["line"] + 1, last + 1):
                self.mentions.append(Mention(c["file"], num, False, False, None, c["n"]))
        return bad


# MARK: - Anchors

def walk_anchors(anchors):
    for a in anchors:
        yield a
        if a["kind"] in ("any", "all"):
            yield from walk_anchors(a["anchors"])


def label_lines(out, path):
    return [out.lines[n - 1] for n in sorted(out.heads.get(path, ()))]


def eval_anchor(a, out, ix, forbidden=False):
    """Returns (matched, stale). Forbidden anchors only see non-exempt segments and strong line mentions."""
    kind = a["kind"]
    where = "site" if forbidden else a.get("in", "any" if kind == "text" else "site")
    if kind in ("any", "all"):
        results = [eval_anchor(x, out, ix, forbidden) for x in a["anchors"]]
        if kind == "any":
            return any(r[0] for r in results), all(r[1] for r in results)
        return all(r[0] for r in results), any(r[1] for r in results)
    if kind == "file":
        hits = [(n, p) for n, p, exempt, label, block in out.paths
                if (p == a["path"] if "path" in a else p.startswith(a["prefix"]))
                and out.segment_ok(exempt, label, where) and (block or a.get("as", "mention") != "block")]
        return bool(hits), False
    if kind == "code":
        line, _, problem = ix.find_code(a)
        if problem:
            return False, True
        return bool(out.mentioned(a["path"], line, where, strong=forbidden, slack=a.get("slack", 0))), False
    if kind == "text":
        flags = re.I if a.get("ci") else 0
        pattern = re.compile(a["text"] if a.get("regex") else re.escape(a["text"]), flags)
        return any(pattern.search(t) for _, t in out.texts(where, a.get("file"), a.get("line"), mask_code=forbidden)), False
    if kind == "label":
        heads = label_lines(out, a["path"])
        owned = [out.lines[n - 1] for n in out.blocks.get(a["path"], ())]
        has = all(any(h in l for l in heads) for h in a.get("has", []))
        lacks = all(not any(h in l for l in owned) for h in a.get("lacks", []))
        if forbidden:
            return bool(heads) and has and bool(a.get("has")), False
        return (bool(heads) or not a.get("has")) and has and lacks, False
    raise ValueError(f"unknown anchor kind {kind}")


def eval_item(item, out, ix):
    failed, stale = [], []
    for i, a in enumerate(item["anchors"]):
        ok, is_stale = eval_anchor(a, out, ix)
        if is_stale:
            stale.append(f"#{i + 1} {a['kind']}")
        if not ok:
            failed.append(f"#{i + 1} {a['kind']}")
    return failed, stale


def eval_forbidden(entry, out, ix):
    results = [eval_anchor(a, out, ix, forbidden=True) for a in entry["anchors"]]
    fired = all(r[0] for r in results)
    stale = [f"#{i + 1} {a['kind']}" for i, (a, r) in enumerate(zip(entry["anchors"], results)) if r[1]]
    return fired, stale


# MARK: - Per-task assertions (b)-(g)

def tokens_of(text):
    return math.ceil(len(text.encode("utf-8")) / 3.0)


def plain_text_problems(out):
    problems = []
    body = "\n".join(out.lines).strip()
    if body.startswith("{"):
        problems.append("starts with {")
    elif body.startswith("["):
        try:
            json.loads(body)
            problems.append("is a JSON array")
        except ValueError:
            pass
    for n, line in enumerate(out.lines, 1):
        visible = line
        for c in out.code:
            if c["n"] == n and c["code"]:
                visible = visible.replace(c["code"], " ")
        for m in SCORE_WORDS.finditer(visible):
            problems.append(f"line {n}: '{m.group(1).lower()}'")
    return problems


def completeness_ok(kind, out):
    line2 = out.lines[1] if len(out.lines) > 1 else ""
    head = "\n".join(out.lines[:2])
    if kind == "complete":
        return bool(re.search(r"\bcomplete\b", line2)) and "INCOMPLETE" not in line2
    if kind == "complete-or-incomplete":
        return bool(re.search(r"\bcomplete\b|\bINCOMPLETE\b", line2))
    if kind == "scope-stamp":
        return bool(re.search(r"scanned \d+ files", head))
    return True


def check_text(text, is_error, exp, budget, ix):
    """Evaluates one tool result against a task's expectations; returns a JSON-able result."""
    out = Output(text, ix)
    bad_code = out.check_fidelity()
    body = "\n".join(out.lines)
    result = {"is_error": is_error, "tokens": tokens_of(body), "budget": budget, "notes": out.notes,
              "first_line": out.lines[0][:200] if out.lines else "",
              "plain_text": plain_text_problems(out), "fidelity": bad_code, "code_lines": len(out.code),
              "items": {}, "forbidden": {}, "stale": []}
    for item in exp.get("items", []):
        failed, stale = eval_item(item, out, ix)
        result["items"][item["id"]] = {"tier": item.get("tier", "must"), "ok": not failed, "failed": failed, "stale": stale}
        if stale:
            result["stale"].append(item["id"])
    for entry in exp.get("forbidden", []):
        fired, stale = eval_forbidden(entry, out, ix)
        result["forbidden"][entry["id"]] = {"fired": fired, "stale": stale}
    result["completeness"] = exp.get("completeness", "none")
    result["completeness_ok"] = completeness_ok(result["completeness"], out)
    return result, out


def verdict(task_id, res, exp, plan_task, p95_limit):
    """Applies the pass rule to a checked result; returns (passed, reasons)."""
    reasons = []
    if res["is_error"]:
        reasons.append("isError")
    if res["plain_text"]:
        reasons.append("not plain text")
    if res["budget"] and res["tokens"] > res["budget"]:
        reasons.append(f"over budget {res['tokens']}>{res['budget']}")
    if res["fidelity"]:
        reasons.append(f"{len(res['fidelity'])} code lines not on disk")
    musts = [i for i, r in res["items"].items() if r["tier"] == "must"]
    passed = [i for i in musts if res["items"][i]["ok"]]
    need = exp.get("min_items") or len(musts)
    if len(passed) < need:
        reasons.append(f"must items {len(passed)}/{len(musts)} (need {need})")
    stale = res["stale"] + [f for f, r in res["forbidden"].items() if r["stale"]]
    if stale:
        reasons.append(f"STALE {','.join(stale)} (re-author)")
    fired = [f for f, r in res["forbidden"].items() if r["fired"]]
    if fired:
        reasons.append(f"forbidden {','.join(fired)}")
    if not res["completeness_ok"]:
        reasons.append(f"completeness ({res['completeness']})")
    for sec in res.get("secondary", []):
        bad = [i for i, r in sec["items"].items() if not r["ok"]]
        if bad or sec["is_error"] is None:
            reasons.append(f"secondary {','.join(bad) or 'not run'}")
    if p95_limit and res.get("p95_ms") is not None and res["p95_ms"] > p95_limit:
        reasons.append(f"p95 {res['p95_ms']:.0f}>{p95_limit} ms")
    return not reasons, reasons


# MARK: - Talking to the server

class GoldenClient(mcp_client.MCPClient):
    """MCPClient plus raw send/read, for requests that must not wait on each other (cold start)."""

    def send(self, method, params=None):
        rid = self.next_id
        self.next_id += 1
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}) + "\n").encode())
        self.proc.stdin.flush()
        return rid, time.monotonic()

    def read_until(self, ids, timeout):
        got, deadline = {}, time.monotonic() + timeout
        while set(ids) - set(got):
            message = self._read_message(deadline)
            if message.get("id") in ids:
                got[message["id"]] = (time.monotonic(), len(got), message)
        return got

    def try_call(self, name, arguments, timeout):
        """tools/call; a JSON-RPC error becomes an error result. A dead or silent server still raises."""
        started = time.monotonic()
        try:
            return self.call(name, arguments, timeout)
        except mcp_client.MCPError as error:
            if "timed out" in str(error) or "server exited" in str(error):
                raise
            return str(error), (time.monotonic() - started) * 1000, True


def text_of(message):
    if "result" not in message:
        return json.dumps(message.get("error")), True
    result = message["result"]
    text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
    return text, bool(result.get("isError"))


def call_arguments(plan_task, question):
    return {k: (question if v == "$question" else v) for k, v in plan_task.get("arguments", {}).items()}


def supports_profile(binary):
    r = subprocess.run([binary, "mcp", "--help"], capture_output=True, text=True)
    return "--profile" in (r.stdout + r.stderr)


def binary_version(binary):
    r = subprocess.run([binary, "--version"], capture_output=True, text=True)
    return (r.stdout or r.stderr).strip()


def catalog_problems(init, tools, list_ms, plan, profile_ok, expected_loaded, gate_state):
    """Catalog checks. `gate_state` maps gate -> passed/None (not run) for the alwaysLoad rule."""
    problems, want = [], list(plan["tools"])
    if not profile_ok:
        problems.append("mcp has no --profile option")
    names = [t.get("name") for t in tools]
    if sorted(names) != sorted(want):
        problems.append(f"{len(tools)} tools, want exactly {len(want)} ({', '.join(want)})")
    tally = defaultdict(list)
    loaded = set()
    for t in tools:
        name, meta = t.get("name"), t.get("_meta") or {}
        if len(t.get("description", "")) > 320:
            tally["description > 320 chars"].append(name)
        props = (t.get("inputSchema") or {}).get("properties") or {}
        if len(props) > 3:
            tally["more than 3 properties"].append(name)
        if "repo" in props:
            tally["`repo` property"].append(name)
        if (t.get("annotations") or {}).get("readOnlyHint") is not True:
            tally["readOnlyHint not true"].append(name)
        if not meta.get("anthropic/searchHint"):
            tally["no searchHint"].append(name)
        always = meta.get("anthropic/alwaysLoad", "absent")
        if always is True:
            loaded.add(name)
        spec = plan["tools"].get(name)
        if spec is None:
            continue
        if expected_loaded is not None:
            if (name in expected_loaded) != (always is True):
                tally["alwaysLoad differs from --expect-loaded"].append(name)
            elif name not in expected_loaded and spec.get("deferred") and always is not False:
                tally["deferred tool without alwaysLoad:false"].append(name)
        elif spec.get("deferred"):
            if always is not False:
                tally["deferred tool without alwaysLoad:false"].append(name)
        elif always is False:
            tally["gated tool sends alwaysLoad:false"].append(name)
        elif always is True and gate_state.get(spec.get("gate")) is False:
            tally[f"alwaysLoad:true but its gate fails"].append(name)
    for what, who in tally.items():
        problems.append(f"{what}: {len(who)} tool{'s' if len(who) != 1 else ''}" + (f" ({', '.join(who)})" if len(who) <= 5 else ""))
    instructions = init.get("instructions") or ""
    if len(instructions) > 4096:
        problems.append(f"instructions {len(instructions)} chars > 4096")
    m = re.search(r"select:([A-Za-z0-9_,]+)", instructions)
    if not m:
        problems.append("instructions have no `select:` line")
    else:
        listed = {s.split("__")[-1] for s in m.group(1).split(",") if s}
        deferred = {n for n in names if n not in loaded}
        if listed != deferred:
            problems.append(f"`select:` lists {sorted(listed)}, deferred are {sorted(deferred)}")
    if list_ms > 50:
        problems.append(f"tools/list {list_ms:.0f} ms > 50")
    return problems


def stale_scenario(binary, run_dir, profile_ok):
    """An external `vesalius index` adds a dependent; the same server's next call must show it."""
    repo, home = os.path.join(run_dir, "stale-fixture"), os.path.join(run_dir, "stale-home")
    os.makedirs(os.path.join(repo, "src"), exist_ok=True)
    os.makedirs(home, exist_ok=True)
    with open(os.path.join(repo, "src", "b.ts"), "w") as f:
        f.write("export function helper() { return 1; }\n")
    with open(os.path.join(repo, "src", "a.ts"), "w") as f:
        f.write('import { helper } from "./b";\nexport const a = helper();\n')
    git = ["git", "-C", repo, "-c", "user.name=golden", "-c", "user.email=golden@localhost", "-c", "commit.gpgsign=false"]
    subprocess.run(git + ["init", "-q"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-qm", "fixture"], check=True)
    client = GoldenClient(repo, binary, env={"VESALIUS_HOME": home},
                          extra_args=["--profile", "default"] if profile_ok else [],
                          log_path=os.path.join(run_dir, "stale-server.log"))
    record = {"before": None, "after": None, "ok": False}
    try:
        client.initialize()
        before, _, before_error = client.try_call("usages", {"target": "src/b.ts"}, 300)
        with open(os.path.join(repo, "src", "c.ts"), "w") as f:
            f.write('import { helper } from "./b";\nexport const c = helper() + 1;\n')
        subprocess.run([binary, "index", repo, "-q", "--no-embeddings", "--no-history"], check=True,
                       env={**os.environ, "VESALIUS_HOME": home}, capture_output=True)
        after, _, after_error = client.try_call("usages", {"target": "src/b.ts"}, 300)
        record.update(before=before, after=after, before_error=before_error, after_error=after_error,
                      ok=not after_error and "src/c.ts" in after)
    except (mcp_client.MCPError, subprocess.CalledProcessError) as error:
        record["error"] = str(error)
    finally:
        client.close()
    return record


# MARK: - Commands

def select_tasks(args, plan):
    if args.tasks:
        return [t.strip() for t in args.tasks.split(",") if t.strip()]
    if args.gate and args.gate != "all":
        return list(plan["gates"][args.gate])
    return list(plan["tasks"])


def task_repos(task_ids, tasks_meta):
    repos = []
    for tid in task_ids:
        if tasks_meta[tid]["repo"] not in repos:
            repos.append(tasks_meta[tid]["repo"])
    return repos


def default_golden_dir():
    return os.environ.get("VESALIUS_GOLDEN_DIR")


def expectations_path(args):
    path = args.expectations or (os.path.join(default_golden_dir(), "expectations.json") if default_golden_dir() else None)
    if not path:
        sys.exit("golden_check: set VESALIUS_GOLDEN_DIR or pass --expectations <file> (kept outside the repository)")
    return outside_repo(path, "--expectations")


def validate(args, plan, tasks_meta):
    """Resolves every anchor in the current trees; STALE anchors need re-authoring."""
    path = expectations_path(args)
    exp = load_json(path)
    indexes, report, stale_total, ambiguous_total = {}, {}, 0, 0
    counts = defaultdict(int)
    for tid, texp in exp["tasks"].items():
        if tid not in plan["tasks"]:
            print(f"{tid:3}  not in plan.json")
            stale_total += 1
            continue
        repo = tasks_meta[tid]["repo"]
        ix = indexes.setdefault(repo, RepoIndex(os.path.join(BENCH_ROOT, repo)))
        rows, seen = [], set()
        groups = [("item", texp.get("items", []))] + [("forbidden", texp.get("forbidden", []))] + \
                 [("secondary", s.get("items", [])) for s in texp.get("secondary", [])]
        for group, entries in groups:
            for entry in entries:
                if entry["id"] in seen:
                    rows.append({"id": entry["id"], "status": "DUPLICATE id"})
                seen.add(entry["id"])
                if group == "item":
                    counts[entry.get("tier", "must")] += 1
                for i, a in enumerate(walk_anchors(entry["anchors"])):
                    counts["anchors"] += 1
                    row = {"id": entry["id"], "group": group, "anchor": i + 1, "kind": a["kind"], "status": "ok"}
                    if a["kind"] == "code":
                        line, hits, problem = ix.find_code(a)
                        row.update(path=a["path"], hint=a.get("line"), line=line, matches=hits)
                        if problem:
                            row["status"], row["why"] = "STALE", problem
                        elif hits > 1 and not a.get("after"):
                            row["status"] = "AMBIGUOUS"
                        elif a.get("line") and line != a["line"]:
                            row["status"] = "drift"
                    elif a["kind"] in ("file", "label") and "path" in a and a["path"] not in ix.paths:
                        row.update(path=a["path"], status="STALE" if group != "forbidden" else "MISSING", why="no such file")
                    elif a["kind"] == "file" and "prefix" in a and not any(p.startswith(a["prefix"]) for p in ix.paths):
                        row.update(prefix=a["prefix"], status="MISSING", why="no file with this prefix")
                    elif a["kind"] == "text" and a.get("regex"):
                        try:
                            re.compile(a["text"])
                        except re.error as error:
                            row.update(status="STALE", why=f"bad regex: {error}")
                    rows.append(row)
        stale = [r for r in rows if r["status"] in ("STALE", "DUPLICATE id")]
        ambiguous = [r for r in rows if r["status"] == "AMBIGUOUS"]
        missing = [r for r in rows if r["status"] == "MISSING"]
        drifted = [r for r in rows if r["status"] == "drift"]
        stale_total += len(stale)
        ambiguous_total += len(ambiguous)
        report[tid] = {"repo": repo, "drift": ix.drift(), "anchors": rows}
        print(f"{tid:3}  {len(texp.get('items', [])):3} items  {len(texp.get('forbidden', [])):3} forbidden  "
              f"{len(rows):4} anchors  stale {len(stale)}  ambiguous {len(ambiguous)}  missing {len(missing)}  moved {len(drifted)}")
        for r in stale + ambiguous + missing:
            print(f"     {r['status']:9} {r['id']} {r.get('group', '')} #{r.get('anchor', '')} {r.get('kind', '')}")
    out_path = os.path.join(os.path.dirname(path), "validation.json")
    with open(out_path, "w") as f:
        json.dump(report, f, indent=1)
    print(f"{sum(len(t.get('items', [])) for t in exp['tasks'].values())} items ({counts['must']} must, {counts['may']} may), "
          f"{counts['anchors']} anchors: {stale_total} STALE, {ambiguous_total} ambiguous · details: {out_path}")
    return 1 if stale_total else 0


def check_saved_text(args, plan, tasks_meta):
    exp = load_json(expectations_path(args))
    tid = args.task
    with open(args.check_text) as f:
        text = f.read()
    ix = RepoIndex(os.path.join(BENCH_ROOT, tasks_meta[tid]["repo"]))
    budget = plan["tools"][plan["tasks"][tid]["tool"]]["budget"]
    res, _ = check_text(text, False, exp["tasks"][tid], budget, ix)
    passed, reasons = verdict(tid, res, exp["tasks"][tid], plan["tasks"][tid], None)
    print_task_details(tid, res)
    for bad in res["fidelity"]:
        print(f"     fidelity: output line {bad['n']} → {bad['file']}:{bad['line']} ({bad['why']})")
    print(f"{tid}: {'PASS' if passed else 'FAIL'}" + (f" ({'; '.join(reasons)})" if reasons else "")
          + f" · {res['code_lines']} quoted code lines checked")
    return 0 if passed else 1


def print_task_details(tid, res):
    missing = [f"{i}({','.join(r['failed'])})" for i, r in res["items"].items() if not r["ok"] and r["tier"] == "must"]
    may = [i for i, r in res["items"].items() if not r["ok"] and r["tier"] == "may"]
    fired = [f for f, r in res["forbidden"].items() if r["fired"]]
    if missing:
        print(f"     {tid} missing: {' '.join(missing)}")
    if may:
        print(f"     {tid} may (not gated) missing: {' '.join(may)}")
    if fired:
        print(f"     {tid} forbidden hits: {' '.join(fired)}")
    stale = res["stale"] + [f for f, r in res["forbidden"].items() if r["stale"]]
    if stale:
        print(f"     {tid} STALE: {' '.join(stale)}")


def run(args, plan, tasks_meta):
    only = set((args.only or "catalog,cold,stale,tasks").split(","))
    task_ids = select_tasks(args, plan) if "tasks" in only or "cold" in only else select_tasks(args, plan)[:1]
    unknown = [t for t in task_ids if t not in plan["tasks"]]
    if unknown:
        sys.exit(f"golden_check: unknown task {', '.join(unknown)}")
    needs_exp = "tasks" in only
    exp = load_json(expectations_path(args)) if needs_exp else {"tasks": {}}
    golden_dir = os.path.dirname(args.expectations) if args.expectations else default_golden_dir()
    runs_root = args.runs_dir or (os.path.join(golden_dir, "runs") if golden_dir else None)
    if not runs_root:
        sys.exit("golden_check: set VESALIUS_GOLDEN_DIR or pass --runs-dir <dir> (kept outside the repository)")
    base = outside_repo(os.path.join(runs_root, time.strftime("%Y%m%dT%H%M%S")), "--runs-dir")
    os.makedirs(runs_root, exist_ok=True)
    run_dir, k = base, 1
    while True:
        try:
            os.mkdir(run_dir)
            break
        except FileExistsError:
            k += 1
            run_dir = f"{base}-{k}"
    binary = os.path.abspath(args.vesalius)
    if not os.path.exists(binary):
        sys.exit(f"golden_check: no binary at {binary}")
    for key in ("VESALIUS_MCP_ALWAYS_LOAD", "VESALIUS_MCP_PROFILE", "VESALIUS_REPO"):
        os.environ.pop(key, None)
    env_extra = {"VESALIUS_MCP_ALWAYS_LOAD": args.always_load} if args.always_load else {}
    expected_loaded = None
    expect = args.expect_loaded or args.always_load or "auto"
    if expect != "auto":
        expected_loaded = set() if expect == "none" else {t.strip() for t in expect.split(",")}
    profile_ok = supports_profile(binary)
    version = binary_version(binary)
    repos = task_repos(task_ids, tasks_meta)
    indexes = {repo: RepoIndex(os.path.join(BENCH_ROOT, repo)) for repo in repos}
    results = {"run": os.path.basename(run_dir), "binary": binary, "version": version, "profile_flag": profile_ok,
               "only": sorted(only), "tasks": task_ids, "repos": {r: ix.drift() for r, ix in indexes.items()},
               "catalog": [], "cold": {}, "stale": None, "repeats": []}
    print(f"golden_check · vesalius {version} · {binary}\nrun {run_dir}")
    print("repos: " + " · ".join(f"{r} {d['head']} ({d['dirty']} dirty, {d['porcelain_sha']})" for r, d in results["repos"].items()))
    if not profile_ok:
        print("note: this binary's `mcp` has no --profile option; the server is started without it")
    for rep in range(args.repeat):
        home = os.path.join(run_dir, f"home-{rep + 1}")
        os.makedirs(home, exist_ok=True)
        rep_record = {"home": home, "tasks": {}, "index": {}}
        for repo in (repos if "tasks" in only or "cold" in only else repos[:1]):
            log = os.path.join(run_dir, f"server-{repo}-r{rep + 1}.log")
            client = GoldenClient(os.path.join(BENCH_ROOT, repo), binary, env={"VESALIUS_HOME": home, **env_extra},
                                  extra_args=["--profile", "default"] if profile_ok else [], log_path=log)
            try:
                init, init_ms = client.initialize()
                tools, list_ms = client.list_tools()
                results["catalog"].append({"repo": repo, "repeat": rep + 1, "init_ms": round(init_ms, 1),
                                           "list_ms": round(list_ms, 1), "tools": tools, "init": init})
                if not ({"tasks", "cold"} & only):
                    continue
                first = True
                for tid in [t for t in task_ids if tasks_meta[t]["repo"] == repo]:
                    plan_task = plan["tasks"][tid]
                    params = {"name": plan_task["tool"], "arguments": call_arguments(plan_task, tasks_meta[tid]["prompt"])}
                    record = {"tool": plan_task["tool"], "arguments": params["arguments"]}
                    if first and "cold" in only:
                        call_id, sent = client.send("tools/call", params)
                        ping_id, ping_sent = client.send("ping")
                        list_id, list_sent = client.send("tools/list")
                        got = client.read_until([call_id, ping_id, list_id], timeout=args.timeout)
                        text, is_error = text_of(got[call_id][2])
                        ms = (got[call_id][0] - sent) * 1000
                        cold = {"task": tid, "call_ms": round(ms, 1),
                                "ping_ms": round((got[ping_id][0] - ping_sent) * 1000, 1),
                                "list_ms": round((got[list_id][0] - list_sent) * 1000, 1),
                                "before_call": got[ping_id][1] < got[call_id][1] and got[list_id][1] < got[call_id][1],
                                "index_note": text.startswith("index: built just now (")}
                        cold["ok"] = cold["ping_ms"] <= 50 and cold["list_ms"] <= 50 and cold["before_call"] and cold["index_note"]
                        results["cold"].setdefault(repo, []).append(cold)
                    else:
                        text, ms, is_error = client.try_call(params["name"], params["arguments"], args.timeout)
                    first = False
                    record.update(text=text, is_error=is_error, ms=round(ms, 1), warm_ms=[])
                    with open(os.path.join(run_dir, f"r{rep + 1}-{tid}.txt"), "w") as f:
                        f.write(text)
                    rep_record["tasks"][tid] = record
                if "tasks" in only:
                    for tid in [t for t in task_ids if tasks_meta[t]["repo"] == repo]:
                        record, plan_task = rep_record["tasks"][tid], plan["tasks"][tid]
                        for _ in range(args.warm):
                            warm, ms, _ = client.try_call(record["tool"], record["arguments"], args.timeout)
                            record["warm_ms"].append(round(ms, 1))
                            record["unstable"] = record.get("unstable", False) or without_notes(warm) != without_notes(record["text"])
                        record["secondary"] = []
                        for k, sec in enumerate(plan_task.get("secondary", [])):
                            stext, sms, serr = client.try_call(sec["tool"], sec["arguments"], args.timeout)
                            record["secondary"].append({"text": stext, "is_error": serr, "ms": round(sms, 1)})
                            with open(os.path.join(run_dir, f"r{rep + 1}-{tid}.secondary-{k + 1}.txt"), "w") as f:
                                f.write(stext)
            except mcp_client.MCPError as error:
                results.setdefault("errors", []).append(f"{repo} r{rep + 1}: {error}")
                print(f"error: {repo}: {error}")
            finally:
                client.close()
        for repo in repos:
            index_dir = os.path.join(home, "Indexes")
            if os.path.isdir(index_dir):
                for name in os.listdir(index_dir):
                    if name.lower().startswith(repo.lower()):
                        sizes = {f: os.path.getsize(os.path.join(index_dir, name, f)) for f in os.listdir(os.path.join(index_dir, name))
                                 if os.path.isfile(os.path.join(index_dir, name, f))}
                        rep_record["index"][repo] = sizes
        if "stale" in only and rep == 0:
            results["stale"] = stale_scenario(binary, run_dir, profile_ok)
            if not args.keep_home:
                shutil.rmtree(os.path.join(run_dir, "stale-home"), ignore_errors=True)
        results["repeats"].append(rep_record)
        if not args.keep_home:
            shutil.rmtree(home, ignore_errors=True)

    # Evaluate.
    task_status = {}
    if "tasks" in only:
        for tid in task_ids:
            plan_task, texp = plan["tasks"][tid], exp["tasks"].get(tid)
            tool = plan["tools"][plan_task["tool"]]
            ix = indexes[tasks_meta[tid]["repo"]]
            per_repeat = []
            for rep_record in results["repeats"]:
                record = rep_record["tasks"].get(tid)
                if record is None or texp is None:
                    per_repeat.append((False, ["not run" if record is None else "no expectations"], None))
                    continue
                res, _ = check_text(record["text"], record["is_error"], texp, tool["budget"], ix)
                res["ms"] = record["ms"]
                warm = sorted(record["warm_ms"])
                res["p95_ms"] = warm[max(0, math.ceil(0.95 * len(warm)) - 1)] if warm else None
                res["unstable"] = record.get("unstable", False)
                res["secondary"] = []
                for k, sec_exp in enumerate(texp.get("secondary", [])):
                    sec = record.get("secondary", [])[k] if k < len(record.get("secondary", [])) else None
                    sres = {"is_error": None, "items": {}}
                    if sec is not None:
                        sout = Output(sec["text"], ix)
                        sres["is_error"] = sec["is_error"]
                        for item in sec_exp["items"]:
                            failed, stale = eval_item(item, sout, ix)
                            sres["items"][item["id"]] = {"tier": "must", "ok": not failed, "failed": failed, "stale": stale}
                    res["secondary"].append(sres)
                passed, reasons = verdict(tid, res, texp, plan_task, tool.get("p95_ms"))
                res["passed"], res["reasons"] = passed, reasons
                rep_record["tasks"][tid]["check"] = res
                per_repeat.append((passed, reasons, res))
            task_status[tid] = per_repeat
    gate_state = {}
    for gate, members in plan["gates"].items():
        ran = [t for t in members if t in task_status]
        gate_state[gate] = None if len(ran) < len(members) else all(all(p for p, _, _ in task_status[t]) for t in members)
    catalog = []
    for c in results["catalog"]:
        catalog.append(catalog_problems(c["init"], c["tools"], c["list_ms"], plan, profile_ok, expected_loaded, gate_state))
    catalog_ok = all(not p for p in catalog) if catalog else None
    cold_ok = (all(c["ok"] for cs in results["cold"].values() for c in cs) if results["cold"] else None) if "cold" in only else None
    stale_ok = results["stale"]["ok"] if results["stale"] else None
    results.update(catalog_ok=catalog_ok, catalog_problems=catalog, cold_ok=cold_ok, stale_ok=stale_ok, gates=gate_state)

    # Report.
    flag = lambda ok: "not run" if ok is None else ("PASS" if ok else "FAIL")
    seen = set()
    print(f"CATALOG  {flag(catalog_ok)}")
    for problems in catalog:
        for p in problems:
            if p not in seen:
                seen.add(p)
                print(f"     {p}")
    if results["catalog"]:
        c0 = results["catalog"][0]
        print(f"     {len(c0['tools'])} tools · {len(json.dumps(c0['tools']))} bytes · tools/list {c0['list_ms']:.0f} ms · "
              f"instructions {len(c0['init'].get('instructions') or '')} chars · server {(c0['init'].get('serverInfo') or {}).get('version')}")
    print(f"COLD     {flag(cold_ok)}")
    for repo, colds in results["cold"].items():
        for c in colds:
            print(f"     {repo} ({c['task']}): call {c['call_ms']:.0f} ms · ping {c['ping_ms']:.0f} ms · tools/list {c['list_ms']:.0f} ms · "
                  f"{'answered before the call' if c['before_call'] else 'queued behind the call'} · "
                  f"{'index note' if c['index_note'] else 'no `index: built just now` note'}")
    print(f"STALE    {flag(stale_ok)}")
    if results["stale"]:
        s = results["stale"]
        detail = s.get("error") or ("after shows src/c.ts" if s["ok"] else f"after: {(s.get('after') or '').splitlines()[0][:80] if s.get('after') else 'no text'}")
        print(f"     {detail}")
    if task_status:
        print(f"{'task':4} {'tool':17} {'status':6} {'must':>7} {'may':>5} {'forbid':>6} {'tokens':>11} {'ms':>7} {'p95':>6}  complete  first line")
        for tid in task_ids:
            plan_task = plan["tasks"][tid]
            for rep, (passed, reasons, res) in enumerate(task_status[tid]):
                gated = plan_task.get("gate") is not None
                status = ("PASS" if passed else "FAIL") if gated else ("info" if res else "FAIL")
                if res is None:
                    print(f"{tid:4} {plan_task['tool']:17} {status:6} {'; '.join(reasons)}")
                    continue
                musts = [r for r in res["items"].values() if r["tier"] == "must"]
                mays = [r for r in res["items"].values() if r["tier"] == "may"]
                fired = sum(1 for r in res["forbidden"].values() if r["fired"])
                print(f"{tid:4} {plan_task['tool']:17} {status:6} {sum(r['ok'] for r in musts):>3}/{len(musts):<3} "
                      f"{sum(r['ok'] for r in mays):>2}/{len(mays):<2} {fired:>6} {res['tokens']:>5}/{res['budget']:<5} "
                      f"{res['ms']:>7.0f} {res['p95_ms'] if res['p95_ms'] is not None else '-':>6}  "
                      f"{'yes' if res['completeness_ok'] else 'no ':3} ({res['completeness']})  {res['first_line'][:60]}")
                if reasons and not passed:
                    print(f"     {tid} r{rep + 1}: {'; '.join(reasons)}")
                print_task_details(tid, res)
                for bad in res["fidelity"][:10]:
                    print(f"     {tid} fidelity: output line {bad['n']} → {bad['file']}:{bad['line']} ({bad['why']})")
    gates_line = " · ".join(f"{g} {flag(None if s is None else s and catalog_ok is not False and cold_ok is not False and stale_ok is not False)}"
                            for g, s in gate_state.items())
    print(f"gates: {gates_line}")
    with open(os.path.join(run_dir, "results.json"), "w") as f:
        json.dump(results, f, indent=1, default=str)
    print(f"results: {os.path.join(run_dir, 'results.json')}")

    checks_ok = all(x is not False for x in (catalog_ok, cold_ok, stale_ok))
    if args.tasks:
        ok = checks_ok and all(all(p for p, _, _ in task_status.get(t, [(False, [], None)])) for t in task_ids
                               if plan["tasks"][t].get("gate") is not None)
    elif "tasks" not in only:
        ok = checks_ok and any(x is not None for x in (catalog_ok, cold_ok, stale_ok))
    elif args.gate in (None, "all"):
        ok = checks_ok and all(gate_state[g] for g in plan["gates"])
    else:
        ok = checks_ok and bool(gate_state.get(args.gate))
    return 0 if ok else 1


def main():
    parser = argparse.ArgumentParser(description="Golden checks for the Vesalius MCP v2 tools (see the module docstring).")
    parser.add_argument("--vesalius", default=mcp_client.DEFAULT_BINARY, help="vesalius binary (default: the package's release build)")
    parser.add_argument("--gate", choices=["G1", "G2", "G3", "all"], help="run that gate's tasks; exit 0 iff it passes")
    parser.add_argument("--tasks", help="comma-separated task ids instead of a gate")
    parser.add_argument("--only", help="subset of catalog,cold,stale,tasks (default: all)")
    parser.add_argument("--repeat", type=int, default=1, help="full runs, each with a fresh VESALIUS_HOME")
    parser.add_argument("--warm", type=int, default=3, help="warm repeats per task for latency p95")
    parser.add_argument("--timeout", type=float, default=900, help="seconds per call (the first call indexes)")
    parser.add_argument("--expect-loaded", help="auto (gate state), none, or the tools that must send alwaysLoad:true")
    parser.add_argument("--always-load", help="set VESALIUS_MCP_ALWAYS_LOAD for the server (and expect it)")
    parser.add_argument("--expectations", help="private expectations (default $VESALIUS_GOLDEN_DIR/expectations.json)")
    parser.add_argument("--runs-dir", help="where runs go (default <golden dir>/runs)")
    parser.add_argument("--keep-home", action="store_true", help="keep each run's VESALIUS_HOME")
    parser.add_argument("--validate-expectations", action="store_true", help="resolve every anchor in today's trees")
    parser.add_argument("--check-text", help="check saved tool text offline (with --task)")
    parser.add_argument("--task", help="task id for --check-text")
    args = parser.parse_args()
    plan = load_json(PLAN_PATH)
    tasks_meta = {t["id"]: t for t in load_json(TASKS_PATH)["tasks"]}
    if args.validate_expectations:
        return validate(args, plan, tasks_meta)
    if args.check_text:
        if not args.task:
            parser.error("--check-text needs --task")
        return check_saved_text(args, plan, tasks_meta)
    return run(args, plan, tasks_meta)


if __name__ == "__main__":
    sys.exit(main())
