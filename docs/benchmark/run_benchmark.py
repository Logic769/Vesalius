#!/usr/bin/env python3
"""Runs each benchmark task through headless Claude Code in up to four setups that differ only in the Vesalius MCP
server and in how tools load: baseline_default and vesalius_deferred (Claude Code's default tool search, without and
with Vesalius; the published comparison), and baseline and vesalius (every tool loaded up front). Everything else is
identical: model, prompt, allowed tools, settings sources. Records Claude Code's own token accounting.

Usage: run_benchmark.py --vesalius <path to vesalius binary> --home <VESALIUS_HOME> --out <dir>
                        [--repos <dir holding the repositories>] [--claude <Claude Code binary>]
                        [--reps 2] [--jobs 6] [--only B3] [--arms baseline,vesalius]

Point --repos at frozen copies (APFS clones) of the repositories: every run then sees the same tree even while
someone keeps working in the originals, and nothing a run does can reach them. Only project settings load, so
neither arm inherits a developer's local permission grants or a repository's auto-memory. Point --claude at one
installed version (~/.local/share/claude/versions/<version>): `claude` on PATH follows whatever version another
session last updated to, and an update mid-run would confound the arms.
"""
import argparse, concurrent.futures as cf, hashlib, json, os, random, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = "claude-opus-5-5"
# Identical in both arms: Claude Code's search/read tools, subagents, and read-only shell commands.
READ_ONLY = [
    "Read", "Grep", "Glob", "LS", "Task", "Agent", "TodoWrite",
    "Bash(grep:*)", "Bash(rg:*)", "Bash(find:*)", "Bash(ls:*)", "Bash(cat:*)", "Bash(head:*)",
    "Bash(tail:*)", "Bash(wc:*)", "Bash(sed -n:*)", "Bash(git grep:*)", "Bash(git log:*)",
    # Read-only filters Claude reaches for when piping search output (denials cost baseline runs a request in v1).
    "Bash(awk:*)", "Bash(sort:*)", "Bash(uniq:*)", "Bash(cut:*)", "Bash(tr:*)", "Bash(git show:*)", "Bash(git ls-files:*)",
]
DISALLOWED = ["Edit", "Write", "NotebookEdit", "MultiEdit", "WebFetch", "WebSearch",
              # Anything that writes, builds or launches, in case a repository's settings allow it.
              "Bash(rm:*)", "Bash(mv:*)", "Bash(cp:*)", "Bash(mkdir:*)", "Bash(touch:*)", "Bash(chmod:*)",
              "Bash(git checkout:*)", "Bash(git restore:*)", "Bash(git reset:*)", "Bash(git pull:*)",
              "Bash(git stash:*)", "Bash(git commit:*)", "Bash(git clean:*)", "Bash(xcodebuild:*)",
              "Bash(swift:*)", "Bash(swiftc:*)", "Bash(npm:*)", "Bash(npx:*)", "Bash(open:*)", "Bash(xcrun:*)"]
SETTING_SOURCES = "project"
# Arms. "baseline" and "vesalius" differ only in the Vesalius MCP server: both load every tool schema up
# front (ENABLE_TOOL_SEARCH=false), so Vesalius is as reachable as Grep. "vesalius_deferred" keeps Claude
# Code's default tool search, where MCP tools must be discovered through ToolSearch before first use.
ARMS = {
    "baseline": {"mcp": False, "env": {"ENABLE_TOOL_SEARCH": "false"}},
    "vesalius": {"mcp": True, "env": {"ENABLE_TOOL_SEARCH": "false"}},
    "vesalius_deferred": {"mcp": True, "env": {}},
    # Claude Code exactly as shipped: default tool search, no Vesalius. Pairs with vesalius_deferred.
    "baseline_default": {"mcp": False, "env": {}},
}


def git_state(repo):
    out = subprocess.run(["git", "status", "--porcelain"], cwd=repo, capture_output=True, text=True).stdout
    return hashlib.sha256(out.encode()).hexdigest()[:12]


def run_one(job, args):
    task, arm, rep = job["task"], job["arm"], job["rep"]
    repo = os.path.join(args.repos, task["repo"])
    name = f"{task['id']}__{arm}__r{rep}"
    transcript = os.path.join(args.out, "transcripts", name + ".jsonl")
    if os.path.exists(transcript) and os.path.getsize(transcript) > 0 and not args.force:
        return parse(transcript, job, cached=True)
    servers = {}
    if ARMS[arm]["mcp"]:
        servers["vesalius"] = {"command": args.vesalius, "args": ["mcp", "--repo", repo], "env": {"VESALIUS_HOME": args.home}}
    config = os.path.join(args.out, "mcp", name + ".json")
    with open(config, "w") as f:
        json.dump({"mcpServers": servers}, f)
    allowed = READ_ONLY + (["mcp__vesalius"] if ARMS[arm]["mcp"] else [])
    prompt = task["prompt"] + "\n\n" + args.suffix
    cmd = [args.claude, "-p", prompt, "--output-format", "stream-json", "--verbose", "--model", MODEL,
           "--setting-sources", SETTING_SOURCES, "--strict-mcp-config", "--mcp-config", config,
           "--allowedTools", *allowed, "--disallowedTools", *DISALLOWED,
           "--no-session-persistence", "--max-turns", "80"]
    started = time.time()
    with open(transcript, "w") as out, open(transcript + ".err", "w") as err:
        env = {k: v for k, v in os.environ.items() if k != "ENABLE_TOOL_SEARCH"}
        env.update(ARMS[arm]["env"], DISABLE_AUTOUPDATER="1")
        subprocess.run(cmd, cwd=repo, stdout=out, stderr=err, stdin=subprocess.DEVNULL, timeout=1800, env=env)
    record = parse(transcript, job, cached=False)
    record["wall_seconds"] = round(time.time() - started, 1)
    return record


def parse(transcript, job, cached):
    task, arm, rep = job["task"], job["arm"], job["rep"]
    tools, mcp_status, results = {}, None, []
    with open(transcript) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") == "system" and event.get("subtype") == "init":
                mcp_status = {s["name"]: s.get("status") for s in event.get("mcp_servers", [])}
            if event.get("type") == "assistant":
                for block in event.get("message", {}).get("content", []) or []:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        tools[block["name"]] = tools.get(block["name"], 0) + 1
            if event.get("type") == "result":
                results.append(event)
    record = {"task": task["id"], "repo": task["repo"], "type": task["type"], "arm": arm, "rep": rep,
              "mcp": mcp_status, "tools": tools, "cached": cached}
    if not results:
        record["error"] = "no result event"
        return record
    # A run that leaves a background task (for example a subagent search) can emit a second result after a
    # follow-up turn. The answer is the first result; usage and cost are cumulative, so totals come from the last.
    first, result = results[0], results[-1]
    totals = {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0}
    for usage in (result.get("modelUsage") or {}).values():
        totals["input"] += usage.get("inputTokens", 0)
        totals["output"] += usage.get("outputTokens", 0)
        totals["cache_read"] += usage.get("cacheReadInputTokens", 0)
        totals["cache_creation"] += usage.get("cacheCreationInputTokens", 0)
    record.update({
        "is_error": result.get("is_error"), "subtype": result.get("subtype"),
        "num_turns": sum(r.get("num_turns") or 0 for r in results),
        "duration_ms": sum(r.get("duration_ms") or 0 for r in results),
        "cost_usd": result.get("total_cost_usd"), "tokens": totals,
        "total_tokens": sum(totals.values()), "models": sorted((result.get("modelUsage") or {}).keys()),
        "answer": first.get("result", ""),
        "followups": [r.get("result", "") for r in results[1:]],
    })
    return record


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--vesalius", required=True)
    parser.add_argument("--home", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--repos", default=os.path.abspath(os.path.join(HERE, "..", "..", "..")),
                        help="folder holding one checkout per tasks.json repository (default: the folder holding this checkout)")
    parser.add_argument("--claude", default="claude", help="the Claude Code binary to run")
    parser.add_argument("--sets", default="", help="only tasks in these sets, e.g. heldout")
    parser.add_argument("--reps", type=int, default=2)
    parser.add_argument("--jobs", type=int, default=6)
    parser.add_argument("--only", default="")
    parser.add_argument("--arms", default="baseline,vesalius,vesalius_deferred")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    spec = json.load(open(os.path.join(HERE, "tasks.json")))
    args.suffix = spec["suffix"]
    os.makedirs(os.path.join(args.out, "transcripts"), exist_ok=True)
    os.makedirs(os.path.join(args.out, "mcp"), exist_ok=True)
    versions = {name: subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
                for name, cmd in (("vesalius", [args.vesalius, "--version"]), ("claude", [args.claude, "--version"]))}
    tasks = [t for t in spec["tasks"] if (not args.only or t["id"] in args.only.split(","))
             and (not args.sets or t.get("set", "original") in args.sets.split(","))]
    heads = {t["repo"]: subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=os.path.join(args.repos, t["repo"]),
                                       capture_output=True, text=True).stdout.strip() for t in tasks}
    json.dump({"versions": versions, "claude_binary": args.claude, "model": MODEL, "arms": args.arms.split(","), "reps": args.reps, "repos": args.repos,
               "heads": heads, "setting_sources": SETTING_SOURCES, "tasks": [t["id"] for t in tasks]},
              open(os.path.join(args.out, "setup.json"), "w"), indent=1)
    print(f"versions: {versions}")
    jobs = [{"task": t, "arm": a, "rep": r} for t in tasks for a in args.arms.split(",") for r in range(1, args.reps + 1)]
    random.Random(7).shuffle(jobs)  # interleave arms so time-of-day and rate limits hit both equally
    repos = sorted({os.path.join(args.repos, t["repo"]) for t in tasks})
    before = {r: git_state(r) for r in repos}
    records = []
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(run_one, j, args): j for j in jobs}
        for done, future in enumerate(cf.as_completed(futures), 1):
            job = futures[future]
            try:
                record = future.result()
            except Exception as error:  # keep going; the record says what failed
                record = {"task": job["task"]["id"], "arm": job["arm"], "rep": job["rep"], "error": repr(error)}
            records.append(record)
            print(f"[{done}/{len(jobs)}] {record['task']} {record['arm']} r{record['rep']}: "
                  f"{record.get('total_tokens', '?')} tokens, {record.get('num_turns', '?')} turns, "
                  f"tools={record.get('tools')} mcp={record.get('mcp')} {record.get('error', '')}", flush=True)
            with open(os.path.join(args.out, "runs.json"), "w") as f:
                json.dump(sorted(records, key=lambda r: (r["task"], r["arm"], r["rep"])), f, indent=1)
    after = {r: git_state(r) for r in repos}
    changed = [r for r in repos if before[r] != after[r]]
    print("repositories unchanged" if not changed else f"WARNING: git status changed in {changed}")
    # Claude Code updates itself; a version change mid-run would confound the arms, so record it at the end too.
    setup_path = os.path.join(args.out, "setup.json")
    setup = json.load(open(setup_path))
    setup["versions_end"] = {"claude": subprocess.run([args.claude, "--version"], capture_output=True, text=True).stdout.strip()}
    setup["repos_changed"] = changed
    json.dump(setup, open(setup_path, "w"), indent=1)
    if setup["versions_end"]["claude"] != setup["versions"]["claude"]:
        print(f"WARNING: Claude Code changed during the run: {setup['versions']['claude']} -> {setup['versions_end']['claude']}")


if __name__ == "__main__":
    main()
