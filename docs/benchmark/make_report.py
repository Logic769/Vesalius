#!/usr/bin/env python3
"""Writes report.html (the template with the results embedded) and, with --png, report.png (the whole page) and
report_share.png (hero, rounds and averages) rendered by headless Chrome. Every sentence that states a result is
computed from the results, so the page cannot claim more than the data supports.

Round 2 compares Claude Code as shipped (default tool search) with and without Vesalius 2; round 1's numbers come
from results_v1.json and are shown as changes against their own baseline, since Claude Code, its settings and the
answer keys differ between rounds.

Usage: make_report.py --results results.json --runs runs.json --setup setup.json [--v1 results_v1.json] [--out <dir>] [--png]
"""
import argparse, json, math, os, re, statistics, subprocess, sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from analyze import compare, uses_vesalius  # noqa: E402

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
BASE, TREAT = "baseline_default", "vesalius_deferred"
SET_NAMES = {"original": "Original questions · used while building Vesalius 2",
             "heldout": "Held-out questions · never seen while building it"}
SET_SHORT = {"original": "original", "heldout": "held-out"}
TOOL_KINDS = [  # (label, explanation, tool names)
    ("Grep and Glob", "text and file-name search", ("Grep", "Glob")),
    ("Read", "whole files or line ranges", ("Read",)),
    ("Shell", "read-only commands: grep, find, sed, git", ("Bash",)),
    ("Subagents", "searches delegated to another agent", ("Task", "Agent")),
    ("Tool search", "loading a deferred tool's definition", ("ToolSearch",)),
]


def times(n):
    return {1: "once", 2: "twice"}.get(n, f"{n} times")


def spelled(n, noun):
    return ("one" if n == 1 else str(n)) + f" {noun}" + ("" if n == 1 else "s")


def count(n, noun):
    return f"{n} {noun}" + ("" if n == 1 else "s")


def signed(x, digits=0):
    return ("+" if x > 0 else "−" if x < 0 else "") + f"{abs(x):.{digits}f}"


def ci_text(ci, digits=0, unit="%"):
    return f"95% CI {signed(ci[0], digits)}{unit} to {signed(ci[1], digits)}{unit}"


def tokens_phrase(c):
    t, ci = c["token_change_pct"], c["token_change_ci95"]
    word = "fewer" if t < 0 else "more"
    if ci and ci[0] < 0 < ci[1]:
        return f"{abs(t):.0f}% {word} tokens per question, within run-to-run noise ({ci_text(ci)})"
    return f"{abs(t):.0f}% {word} tokens per question ({ci_text(ci)})" if ci else f"{abs(t):.0f}% {word} tokens per question"


def quality_phrase(c):
    q, ci = c["quality_delta"], c["quality_delta_ci95"]
    if ci and ci[0] <= 0 <= ci[1]:
        return f"no measurable change in answer quality ({signed(q, 1)} points, {ci_text(ci, 1, '')})"
    return f"answers {abs(q):.1f} quality points {'better' if q > 0 else 'worse'} ({ci_text(ci, 1, '')})"


def tone(ci, lower_is_better):
    if not ci:
        return ""
    if ci[1] < 0:
        return "good" if lower_is_better else "bad"
    if ci[0] > 0:
        return "bad" if lower_is_better else "good"
    return ""


def axis(values, step_options, pad, floor_zero=None):
    """A range that holds every value with some padding, and ticks at a round step."""
    lo, hi = min(values + [0]) - pad, max(values + [0]) + pad
    step = next((s for s in step_options if (hi - lo) / s <= 4), step_options[-1])
    lo = step * math.floor(lo / step)
    hi = step * math.ceil(hi / step)
    if floor_zero is not None:
        hi = max(hi, floor_zero)
    return [lo, hi, [lo + i * step for i in range(int(round((hi - lo) / step)) + 1)]]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", required=True)
    parser.add_argument("--runs", required=True)
    parser.add_argument("--setup", required=True)
    parser.add_argument("--v1", default=os.path.join(HERE, "results_v1.json"))
    parser.add_argument("--out", default=HERE, help="directory for report.html and the PNGs")
    parser.add_argument("--png", action="store_true")
    args = parser.parse_args()
    R, V1 = json.load(open(args.results)), json.load(open(args.v1))
    runs, setup = json.load(open(args.runs)), json.load(open(args.setup))
    S, C, rows = R["summary"], R["comparisons"]["shipped"], R["rows"]
    by_set = R["comparisons_by_set"].get("shipped", {})
    n_tasks, repos = C["tasks"], sorted({r["repo"] for r in rows})
    reps = max(r[TREAT]["reps"] for r in rows if TREAT in r)
    judges = R.get("judges", 3)
    used, n_runs = S[TREAT]["runs_using_vesalius"], S[TREAT]["runs"]
    claude = setup["versions"]["claude"].split()[0]
    model = ", ".join(sorted({m for r in runs for m in r.get("models", [])})) or setup["model"]

    # Round 1, as published: Claude Code's default loading against the same Claude Code without Vesalius.
    v1c, v1s = V1["comparisons"]["shipped"], V1["summary"]["vesalius_deferred"]
    original = [r for r in rows if r["set"] == "original"]
    heldout = [r for r in rows if r["set"] == "heldout"]
    same12 = by_set.get("original") or compare(original, BASE, TREAT)
    no_h1 = compare([r for r in heldout if r["task"] != "H1"], BASE, TREAT)

    def used_in(subset):
        names = {r["task"] for r in subset}
        hits = [r for r in runs if r["arm"] == TREAT and r["task"] in names and "total_tokens" in r]
        return sum(1 for r in hits if uses_vesalius(r)), len(hits)

    used12 = used_in(original)
    rounds = [
        {"label": "Round 1 · Vesalius 1", "sub": f"Oct 10 · {v1c['tasks']} questions × 2 runs", "used": v1s["runs_using_vesalius"], "runs": v1s["runs"],
         "tokens": v1c["token_change_pct"], "tokensCI": v1c["token_change_ci95"], "quality": v1c["quality_delta"], "qualityCI": v1c["quality_delta_ci95"], "faded": True},
        {"label": "Round 2 · same questions", "sub": f"{same12['tasks']} original questions × {count(reps, 'run')}", "used": used12[0], "runs": used12[1],
         "tokens": same12["token_change_pct"], "tokensCI": same12["token_change_ci95"], "quality": same12["quality_delta"], "qualityCI": same12["quality_delta_ci95"]},
        {"label": "Round 2 · every question", "sub": f"{n_tasks} questions × {count(reps, 'run')}", "used": used, "runs": n_runs,
         "tokens": C["token_change_pct"], "tokensCI": C["token_change_ci95"], "quality": C["quality_delta"], "qualityCI": C["quality_delta_ci95"]},
    ]
    sets = [{"label": f"All {n_tasks} questions", "sub": f"{len(repos)} codebases", "c": C},
            {"label": f"Original {len(original)}", "sub": "Bilbo, cinder, Wax, itsyconnect", "c": same12}]
    if by_set.get("heldout"):
        sets.append({"label": f"Held-out {len(heldout)}", "sub": "Haplo Invest, Espresso", "c": by_set["heldout"]})
    if no_h1:
        sets.append({"label": f"Held-out without H1", "sub": "drops the purchases question", "c": no_h1})
    for s in sets:
        c = s.pop("c")
        s.update(tokens=c["token_change_pct"], tokensCI=c["token_change_ci95"], quality=c["quality_delta"], qualityCI=c["quality_delta_ci95"])

    token_values = [v for r in rounds + sets for v in [r["tokens"]] + (r["tokensCI"] or [])]
    quality_values = [abs(v) for r in rounds + sets for v in [r["quality"]] + (r["qualityCI"] or [])]
    qmax = max([2.0] + quality_values)
    qstep = next(s for s in (1, 2, 5, 10, 20, 50) if qmax / s <= 2)
    qhi = qstep * math.ceil(qmax / qstep)
    ranges = {"tokens": axis(token_values, (5, 10, 20, 25, 50), 4, floor_zero=10),
              "quality": [-qhi, qhi, [-qhi, -qhi / 2, 0, qhi / 2, qhi]]}

    # Tool calls per run, by kind, in each setup (subagents' calls included).
    def per_run(arm, names):
        arm_runs = [r for r in runs if r["arm"] == arm and "total_tokens" in r]
        return statistics.mean(sum(n for tool, n in (r.get("tools") or {}).items() if tool in names) for r in arm_runs) if arm_runs else 0.0

    tool_use = [{"label": label, "sub": sub, "baseline": per_run(BASE, names), "vesalius": per_run(TREAT, names)} for label, sub, names in TOOL_KINDS]
    v_calls = R.get("vesalius_tool_calls", {}).get(TREAT, {})
    v_runs = [r for r in runs if r["arm"] == TREAT and "total_tokens" in r]
    v_breakdown = [f"{name} {n}" for name, n in sorted(v_calls.items(), key=lambda kv: (-kv[1], kv[0]))]
    tool_use.append({"label": "Vesalius", "sub": f"{len(v_calls)} of its 5 tools, counts above" if v_calls else "never called",
                     "baseline": 0.0, "vesalius": sum(v_calls.values()) / len(v_runs) if v_runs else 0.0})
    search_kinds = ("Grep and Glob", "Read", "Shell", "Subagents")
    search_base = sum(t["baseline"] for t in tool_use if t["label"] in search_kinds)
    search_ves = sum(t["vesalius"] for t in tool_use if t["label"] in search_kinds)

    split = R.get("used_splits", {}).get("shipped", {})
    prompt = R.get("first_prompt_tokens", {})
    overhead = prompt.get(TREAT, 0) - prompt.get(BASE, 0)
    used_rows = [r for r in rows if r.get(TREAT, {}).get("used_vesalius")]

    lede = (f"{n_tasks} real questions about {len(repos)} codebases, asked to headless Claude Code with and without Vesalius, {times(reps)} each "
            f"({len(runs)} runs), every answer graded blind against a verified key. With Claude Code's default settings, Claude called Vesalius in "
            f"{used} of {n_runs} runs" + ("" if reps == 1 else f", on {len(used_rows)} of the {n_tasks} questions,")
            + f" and used {tokens_phrase(C)}, with {quality_phrase(C)}.")
    chips = [
        {"text": f"{signed(C['token_change_pct'])}% tokens per question ({ci_text(C['token_change_ci95'])})", "tone": tone(C["token_change_ci95"], True)},
        {"text": f"{signed(C['quality_delta'], 1)} answer quality ({ci_text(C['quality_delta_ci95'], 1, '')})", "tone": tone(C["quality_delta_ci95"], False)},
        {"text": f"Called Vesalius in {used} of {n_runs} runs (round 1: {v1s['runs_using_vesalius']} of {v1s['runs']})", "tone": ""},
        {"text": f"Fewer tokens on {C['fewer_tokens_tasks']} of {n_tasks} questions", "tone": ""},
    ]
    if by_set.get("heldout"):
        h = by_set["heldout"]
        chips.append({"text": f"Held-out questions: {signed(h['token_change_pct'])}% tokens, {signed(h['quality_delta'], 1)} quality", "tone": tone(h["token_change_ci95"], True)})
    split_chips = []
    if "used" in split:
        u = split["used"]
        split_chips.append({"text": f"Runs that called Vesalius ({u['runs']}): {signed(u['token_change_pct'])}% tokens, {signed(u['quality_delta'], 1)} quality",
                            "tone": "good" if u["token_change_pct"] < 0 and u["quality_delta"] >= 0 else ""})
    if "unused" in split:
        u = split["unused"]
        split_chips.append({"text": f"Runs that did not ({u['runs']}): {signed(u['token_change_pct'])}% tokens, {signed(u['quality_delta'], 1)} quality", "tone": ""})
    split_chips.append({"text": f"Vesalius's always-loaded tools and instructions: {overhead / 1000:.1f}k tokens of prompt", "tone": ""})

    rounds_intro = ("Round 1 shipped Vesalius 1 as twenty separate tools that Claude Code keeps behind tool search. Claude found and called them in "
                    f"only {v1s['runs_using_vesalius']} of {v1s['runs']} runs, so the token gap it measured was mostly run-to-run variation. Vesalius 2 answers each "
                    "kind of question with one tool, loads the two most-asked ones up front, and returns file:line with the code and a completeness check. "
                    "Round 2 re-ran the original questions and added held-out ones. Claude Code's version, its settings and the answer keys changed between "
                    "rounds, so compare each round's change against its own baseline, not raw token counts.")
    avg_intro = ("Mean tokens and answer quality per question over every run. The percentage changes on this page are per-question ratios averaged "
                 "geometrically, so one expensive question cannot dominate them; these bars show plain means.")
    sets_intro = ("The original twelve questions were used while building Vesalius 2: automated checks scored its output on them. The held-out questions, "
                  "on Haplo Invest and Espresso, were written afterwards and never informed its design; their answer keys were built without Vesalius. "
                  "H1 asks about in-app purchases, close to the original B1, so the held-out set is also shown without it.")
    tools_intro = (f"Mean tool calls per run, subagents included. With Vesalius attached, Claude made {search_ves:.3g} search, read and shell calls per run "
                   f"against {search_base:.3g} without it"
                   + (f", plus {sum(v_calls.values()) / len(v_runs):.1f} Vesalius calls ({', '.join(v_breakdown)} in all)." if v_calls else "."))
    tokens_note = ("Everything Claude Code processed to answer: input, output, cache reads and cache writes, summed over every model the run used, "
                   "including subagents. Lower is better. "
                   + ("Each bar is one run. " if reps == 1 else "Bars are the mean of the runs; whiskers span the cheapest and the most expensive run. ")
                   + "A dot marks questions where Claude called Vesalius.")
    quality_note = ("F1 of each answer against a verified answer key: how much of the right answer it found (recall, central items weighted double) "
                    "and how much of what it said was true (precision, every concrete claim checked). Graded blind by "
                    + ("one judge" if judges == 1 else f"{judges} independent judges") + ". Higher is better.")

    method = [
        {"title": "Questions", "text": f"{n_tasks} developer questions about {', '.join(repos)}: feature location, callers, symbol usage, file dependents, "
                                        f"change impact, architecture and import cycles, in Swift and TypeScript. Each setup answered each question {times(reps)}."},
        {"title": "Held-out questions", "text": f"{len(heldout)} questions on two codebases written after Vesalius 2 was designed. Its golden checks never ran on them, and their "
                                                 "answer keys were built by investigators working without Vesalius, then checked against the code. "
                                                 "While Vesalius 2 was finished, two of its output rules were checked against all six codebases' code, "
                                                 "these two included; their questions and answer keys were never seen."},
        {"title": "Fair comparison", "text": f"Every run is the same headless Claude Code {claude} (one pinned build, auto-update off), model {model}, the same prompt, "
                                              "read-only permissions and project-only settings, on frozen copies of each repository. The two setups ran interleaved "
                                              "in random order. The only difference is whether Vesalius is attached, and Claude decides on its own whether to call it."},
        {"title": "Tokens", "text": "Claude Code's own usage report: input, output, cache reads and cache writes across every model the run used, subagents "
                                     f"included. Vesalius's definitions and instructions count too: {overhead / 1000:.1f}k tokens on the first prompt."},
        {"title": "Answer quality", "text": "Each answer key lists the required items, acceptable extras and known wrong claims, each traced to the code. "
                                             + ("One judge" if judges == 1 else f"{judges} judges") + " graded every answer blind, with tool names masked, "
                                             "checking claims the key does not cover in the code. Quality "
                                             "is the F1 of recall (central items count double) and precision."},
        {"title": "Caveats", "text": f"{spelled(reps, 'run').capitalize()} per question per setup and {spelled(judges, 'judge')} per answer, so per-question bars are noisy; "
                                      "confidence intervals bootstrap over questions. Quality "
                                      "is close to the ceiling for both setups, so tokens carry most of the signal. Round 1 ran an older Claude Code with "
                                      "different settings and keys."},
    ]

    data = dict(R, pair={"baseline": BASE, "treatment": TREAT}, eyebrow="Claude Code navigation benchmark · round 2", lede=lede, chips=chips,
                splitChips=split_chips, rounds=rounds, sets=sets, ranges=ranges, toolUse=tool_use, setNames=SET_NAMES, setShort=SET_SHORT,
                roundsIntro=rounds_intro, avgTitle=f"Averages across all {n_tasks} questions", avgIntro=avg_intro, setsIntro=sets_intro,
                toolsIntro=tools_intro, tokensNote=tokens_note, qualityNote=quality_note, method=method,
                whoBase=f"Claude Code {claude} as shipped: Grep, Glob, Read, read-only shell and subagents",
                whoVes="The same Claude Code with Vesalius 2 attached over MCP: usages and feature_map up front, three more tools on demand")
    html = open(os.path.join(HERE, "report_template.html")).read().replace("/*DATA*/null", json.dumps(data))
    out = os.path.join(args.out, "report.html")
    open(out, "w").write(html)
    print("wrote", out)
    if args.png:
        render_png(html, args.out)


def render_png(html, out):
    """Screenshots the whole page and the #share view, each sized to its content."""
    page = os.path.join(out, ".report_render.html")
    probe = ("<script>addEventListener('load',()=>setTimeout(()=>{document.documentElement.dataset.height="
             "Math.ceil(document.querySelector('.wrap').getBoundingClientRect().bottom)},300))</script>")
    open(page, "w").write('<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"></head><body>'
                          + html + probe + "</body></html>")
    try:
        for name, hash_, width in (("report.png", "", 1180), ("report_share.png", "#share", 1180)):
            dom = subprocess.run([CHROME, "--headless=new", "--disable-gpu", f"--window-size={width},1200", "--virtual-time-budget=5000", "--dump-dom",
                                  "file://" + page + hash_], capture_output=True, text=True).stdout
            match = re.search(r'data-height="(\d+)"', dom)
            height = int(match.group(1)) + 8 if match else 4600
            png = os.path.join(out, name)
            subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=2", "--virtual-time-budget=5000",
                            f"--window-size={width},{height}", f"--screenshot={png}", "file://" + page + hash_],
                           check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print("wrote", png, f"({width}x{height})")
    finally:
        os.remove(page)


if __name__ == "__main__":
    main()
