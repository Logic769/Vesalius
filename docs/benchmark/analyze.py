#!/usr/bin/env python3
"""Turns raw runs and blinded judge grades into the benchmark results.

Quality of one answer, per judge: weighted recall R (share of the answer key's required items the answer
contains, central items count double) and precision P (share of the answer's concrete claims that are
correct). Score = 100 * F1(R, P). An answer's quality is the mean over its judges; a task's is the mean over
its runs. Tokens are Claude Code's own accounting: input + output + cache reads + cache writes, summed over
every model the run used (subagents included).

Two paired comparisons, each differing only in whether Vesalius is attached:
  shipped: Claude Code's default deferred tool loading   (baseline_default vs vesalius_deferred)
  loaded:  every tool schema loaded up front              (baseline vs vesalius)
Each comparison is also reported per task set (tasks.json "set": the original questions, and held-out questions
written after Vesalius was tuned) and per question type.

Usage: analyze.py --runs runs.json --grades grades.json --map blind_map.json --keys answer_keys.json
                  --transcripts <dir> --out results.json
"""
import argparse, glob, json, math, os, random, statistics

ARMS = ["baseline_default", "vesalius_deferred", "baseline", "vesalius"]
PAIRS = {"shipped": ("baseline_default", "vesalius_deferred"), "loaded": ("baseline", "vesalius")}


def f1(recall, precision):
    return 0.0 if recall + precision == 0 else 2 * recall * precision / (recall + precision)


def judge_scores(grade, key):
    weights = {item["id"]: float(item.get("weight", 1)) for item in key["required"]}
    total = sum(weights.values()) or 1.0
    matched = {m if isinstance(m, str) else m.get("id") for m in grade.get("matched", [])} & set(weights)
    recall = sum(weights[i] for i in matched) / total
    correct, wrong = int(grade.get("correct_claims", 0)), int(grade.get("incorrect_claims", 0))
    precision = correct / (correct + wrong) if correct + wrong else 0.0
    return {"recall": recall, "precision": precision, "f1": f1(recall, precision),
            "holistic": float(grade.get("holistic", 0)) / 10.0, "wrong_claims": wrong}


def geo(xs):
    return math.exp(statistics.mean(math.log(x) for x in xs))


def bootstrap(values, fn, n=4000, seed=3):
    rng = random.Random(seed)
    stats = sorted(fn([rng.choice(values) for _ in values]) for _ in range(n))
    return [stats[int(0.025 * n)], stats[int(0.975 * n)]]


def compare(rows, base, treat):
    paired = [r for r in rows if base in r and treat in r and r[base]["quality"] is not None and r[treat]["quality"] is not None]
    if not paired:
        return None
    ratios = [r[treat]["tokens"] / r[base]["tokens"] for r in paired]
    deltas = [r[treat]["quality"] - r[base]["quality"] for r in paired]
    costs = [r[treat]["cost"] / r[base]["cost"] for r in paired]
    return {
        "baseline": base, "treatment": treat, "tasks": len(paired),
        "token_change_pct": 100 * (geo(ratios) - 1),
        "token_change_ci95": [100 * (x - 1) for x in bootstrap(ratios, geo)] if len(paired) > 1 else None,
        "cost_change_pct": 100 * (geo(costs) - 1),
        "quality_delta": statistics.mean(deltas),
        "quality_delta_ci95": bootstrap(deltas, statistics.mean) if len(paired) > 1 else None,
        "usefulness_delta": statistics.mean(r[treat]["usefulness"] - r[base]["usefulness"] for r in paired),
        "turns_change_pct": 100 * (geo([max(r[treat]["turns"], 1) / max(r[base]["turns"], 1) for r in paired]) - 1),
        "seconds_change_pct": 100 * (geo([max(r[treat]["seconds"], 1) / max(r[base]["seconds"], 1) for r in paired]) - 1),
        "fewer_tokens_tasks": sum(1 for x in ratios if x < 1),
        "better_quality_tasks": sum(1 for d in deltas if d >= 1),
        "worse_quality_tasks": sum(1 for d in deltas if d <= -1),
    }


def uses_vesalius(run):
    return any(k.startswith("mcp__vesalius") for k in run.get("tools", {}))


def first_prompt_sizes(transcripts):
    sizes = {}
    for path in glob.glob(os.path.join(transcripts, "*.jsonl")):
        arm = os.path.basename(path).split("__")[1]
        for line in open(path):
            event = json.loads(line)
            if event.get("type") == "assistant" and not event.get("parent_tool_use_id"):
                u = event["message"].get("usage", {})
                sizes.setdefault(arm, []).append(u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0) + u.get("cache_read_input_tokens", 0))
                break
    return {arm: statistics.median(v) for arm, v in sizes.items()}


def main():
    parser = argparse.ArgumentParser()
    for name in ("runs", "grades", "map", "keys", "transcripts", "out"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    runs = json.load(open(args.runs))
    grades = json.load(open(args.grades))          # {gid: [judge grade, ...]}
    blind = json.load(open(args.map))              # {gid: {task, arm, rep}}
    keys = {k["task"]: k for k in json.load(open(args.keys))}

    quality = {}
    for gid, info in blind.items():
        scores = [judge_scores(g, keys[info["task"]]) for g in grades.get(gid, []) if g]
        if scores:
            q = {m: statistics.mean(s[m] for s in scores) for m in scores[0]}
            q["judges"] = len(scores)
            q["spread"] = max(s["f1"] for s in scores) - min(s["f1"] for s in scores)
            quality[(info["task"], info["arm"], info["rep"])] = q
    for run in runs:
        q = quality.get((run["task"], run["arm"], run["rep"]))
        run["quality"] = 100 * q["f1"] if q else None
        run["recall"] = 100 * q["recall"] if q else None
        run["precision"] = 100 * q["precision"] if q else None
        run["usefulness"] = 100 * q["holistic"] if q else None

    tasks = sorted({r["task"] for r in runs})
    rows = []
    for task in tasks:
        row = {"task": task}
        for arm in ARMS:
            reps = [r for r in runs if r["task"] == task and r["arm"] == arm and "total_tokens" in r]
            if not reps:
                continue
            graded = [r for r in reps if r["quality"] is not None]
            row["type"], row["repo"] = reps[0]["type"], reps[0]["repo"]
            row[arm] = {
                "tokens": statistics.mean(r["total_tokens"] for r in reps),
                "tokens_range": [min(r["total_tokens"] for r in reps), max(r["total_tokens"] for r in reps)],
                "cost": statistics.mean(r.get("cost_usd") or 0 for r in reps),
                "turns": statistics.mean(r.get("num_turns") or 0 for r in reps),
                "seconds": statistics.mean((r.get("duration_ms") or 0) / 1000 for r in reps),
                "used_vesalius": sum(1 for r in reps if uses_vesalius(r)),
                "reps": len(reps),
                "quality": statistics.mean(r["quality"] for r in graded) if graded else None,
                "quality_range": [min(r["quality"] for r in graded), max(r["quality"] for r in graded)] if graded else None,
                "recall": statistics.mean(r["recall"] for r in graded) if graded else None,
                "precision": statistics.mean(r["precision"] for r in graded) if graded else None,
                "usefulness": statistics.mean(r["usefulness"] for r in graded) if graded else None,
            }
        rows.append(row)

    summary = {}
    for arm in ARMS:
        present = [r for r in rows if arm in r and r[arm]["quality"] is not None]
        if present:
            summary[arm] = {
                "tasks": len(present),
                "mean_tokens": statistics.mean(r[arm]["tokens"] for r in present),
                "median_task_tokens": statistics.median(r[arm]["tokens"] for r in present),
                "mean_cost": statistics.mean(r[arm]["cost"] for r in present),
                "mean_turns": statistics.mean(r[arm]["turns"] for r in present),
                "mean_seconds": statistics.mean(r[arm]["seconds"] for r in present),
                "quality": statistics.mean(r[arm]["quality"] for r in present),
                "recall": statistics.mean(r[arm]["recall"] for r in present),
                "precision": statistics.mean(r[arm]["precision"] for r in present),
                "usefulness": statistics.mean(r[arm]["usefulness"] for r in present),
                "runs_using_vesalius": sum(r[arm]["used_vesalius"] for r in present),
                "runs": sum(r[arm]["reps"] for r in present),
            }

    here = os.path.dirname(os.path.abspath(__file__))
    sets = {t["id"]: t.get("set", "original") for t in json.load(open(os.path.join(here, "tasks.json")))["tasks"]}
    for row in rows:
        row["set"] = sets.get(row["task"], "original")
    comparisons, by_set, by_type = {}, {}, {}
    for name, (base, treat) in PAIRS.items():
        c = compare(rows, base, treat)
        if c:
            comparisons[name] = c
        for set_name in sorted({r["set"] for r in rows}):
            c = compare([r for r in rows if r["set"] == set_name], base, treat)
            if c:
                by_set.setdefault(name, {})[set_name] = c
        for kind in sorted({r.get("type") for r in rows if r.get("type")}):
            c = compare([r for r in rows if r.get("type") == kind], base, treat)
            if c:
                by_type.setdefault(name, {})[kind] = c

    # Runs of each Vesalius setup, split by whether Claude called Vesalius, against the same task's baseline mean.
    splits = {}
    for name, (base_arm, arm) in PAIRS.items():
        for used in (True, False):
            pairs = []
            for r in runs:
                if r["arm"] != arm or uses_vesalius(r) != used or "total_tokens" not in r:
                    continue
                base = next((row[base_arm] for row in rows if row["task"] == r["task"] and base_arm in row), None)
                if base and base["quality"] is not None and r["quality"] is not None:
                    pairs.append((r["total_tokens"] / base["tokens"], r["quality"] - base["quality"]))
            if pairs:
                splits.setdefault(name, {})["used" if used else "unused"] = {
                    "runs": len(pairs),
                    "token_change_pct": 100 * (geo([p[0] for p in pairs]) - 1),
                    "quality_delta": statistics.mean(p[1] for p in pairs),
                }
    split = splits.get("loaded", {})
    tool_calls = {}
    for r in runs:
        for tool, n in (r.get("tools") or {}).items():
            if tool.startswith("mcp__vesalius__"):
                tool_calls.setdefault(r["arm"], {}).setdefault(tool.split("__")[-1], 0)
                tool_calls[r["arm"]][tool.split("__")[-1]] += n

    out = {"rows": rows, "summary": summary, "comparisons": comparisons, "comparisons_by_set": by_set,
           "comparisons_by_type": by_type, "vesalius_used_split": split, "used_splits": splits,
           "vesalius_tool_calls": tool_calls, "first_prompt_tokens": first_prompt_sizes(args.transcripts),
           # Judges per graded answer (the usual count, should a judge have failed on a few).
           "judges": statistics.mode(q["judges"] for q in quality.values()) if quality else 0}
    json.dump(out, open(args.out, "w"), indent=1)
    print(json.dumps({k: out[k] for k in ("summary", "comparisons", "comparisons_by_set", "used_splits",
                                          "vesalius_tool_calls", "first_prompt_tokens")}, indent=1))


if __name__ == "__main__":
    main()
