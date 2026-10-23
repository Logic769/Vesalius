#!/usr/bin/env python3
"""Builds blinded grading panels: for every task, one file per judge holding the question, the verified answer
key and all answers to that task under opaque ids, in a different order for each judge. The setup that produced
each answer is kept in a separate map the judges never see, and mentions of tools are masked so the wording
does not reveal it.

Usage: prep_grading.py --runs runs.json --keys answer_keys.json --out <dir> --map blind_map.json [--judges 3]
                       [--repos <dir holding the repositories the runs used>]
"""
import argparse, json, os, random, re

# Only wording that names the tool is rewritten, into neutral words both setups use ("MCP" stays: some
# of these codebases have their own MCP code). The answer keys get the same treatment.
TOOL_NAMES = ("search_codebase", "find_symbol", "find_files", "find_references", "find_callers", "find_callees",
              "get_file_context", "get_symbol_context", "get_dependencies", "get_dependents", "get_change_impact",
              "get_dependency_graph", "get_architecture_summary", "get_code_health", "get_hotspots", "get_cycles",
              "get_unused_code", "get_related_files", "get_repository_overview", "reindex_repository")
# v2 tool names. "usages", "outline" and "architecture" are ordinary words in answers, so they are masked only in
# tool syntax (mcp__vesalius__usages, `usages(...)`, "the usages tool"), never as plain prose.
V2_TOOL_SYNTAX = (r"mcp__vesalius__\w+|\bfeature_map\b|\bdependency_cycles\b|\brepo_report\b|"
                  r"`?\b(?:usages|outline|architecture)\b`?(?=\s*\(|\s+tool\b)")
MASK = re.compile(r"(the )?(vesalius( tool| code graph| index)?|code[- ]index(es)?|codebase index|" + "|".join(TOOL_NAMES)
                  + "|" + V2_TOOL_SYNTAX + r")", re.IGNORECASE)


def neutral(text):
    return MASK.sub("the search", text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", required=True)
    parser.add_argument("--keys", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--map", required=True)
    parser.add_argument("--judges", type=int, default=3)
    parser.add_argument("--repos", default=os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")),
                        help="folder holding one checkout per tasks.json repository (default: the folder holding this checkout)")
    args = parser.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    tasks = {t["id"]: t for t in json.load(open(os.path.join(here, "tasks.json")))["tasks"]}
    keys = {k["task"]: k for k in json.load(open(args.keys))}
    runs = [r for r in json.load(open(args.runs)) if r.get("answer") and not r.get("error")]
    os.makedirs(args.out, exist_ok=True)
    panels = []
    if os.path.exists(args.map):  # ids stay stable when panels are built in batches as keys finish
        blind = json.load(open(args.map))
    else:
        rng = random.Random(11)
        rng.shuffle(runs)
        blind = {f"A{index:03d}": {"task": r["task"], "arm": r["arm"], "rep": r["rep"]} for index, r in enumerate(runs, 1)}
    for task_id, task in tasks.items():
        if task_id not in keys:
            continue
        answers = [{"id": gid, "answer": neutral(next(r["answer"] for r in runs if r["task"] == info["task"]
                    and r["arm"] == info["arm"] and r["rep"] == info["rep"]))}
                   for gid, info in blind.items() if info["task"] == task_id]
        for judge in range(1, args.judges + 1):
            order = answers[:]
            random.Random(f"{task_id}-{judge}").shuffle(order)
            path = os.path.join(args.out, f"{task_id}-judge{judge}.json")
            with open(path, "w") as f:
                json.dump({"task": task_id, "repository": os.path.join(args.repos, task["repo"]),
                           "question": task["prompt"], "answer_key": json.loads(neutral(json.dumps(keys[task_id]))), "answers": order}, f, indent=1)
            panels.append({"task": task_id, "judge": judge, "path": path, "repository": os.path.join(args.repos, task["repo"]), "count": len(order)})
    with open(args.map, "w") as f:
        json.dump(blind, f, indent=1)
    with open(os.path.join(args.out, "panels-" + "-".join(sorted(keys)) + ".json"), "w") as f:
        json.dump(panels, f, indent=1)
    print(f"{len(blind)} answers, {len(panels)} judge panels in {args.out}")


if __name__ == "__main__":
    main()
