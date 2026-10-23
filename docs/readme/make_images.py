#!/usr/bin/env python3
"""Renders the README's images from cards.html and the benchmark results, in a dark and a light variant each.

Usage: make_images.py [--setup <benchmark setup.json>]

Writes docs/readme/{banner,hero,rounds}-{dark,light}.png (2x, transparent corners). The app screenshots in
docs/readme/screens/ are committed as they are. Needs Google Chrome; fonts load from Google Fonts.
"""
import argparse, base64, json, os, re, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
BENCH = os.path.join(ROOT, "docs", "benchmark")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
CARDS = ("banner", "hero", "rounds")
BASE, TREAT = "baseline_default", "vesalius_deferred"


def mark_svg():
    """The brand mark with its colours turned into theme tokens: plain dots, the V's dots and the coral root."""
    svg = open(os.path.join(ROOT, "docs", "brand", "vesalius-mark.svg")).read()

    def recolor(match):
        r, g, b = (int(x) for x in match.groups())
        if r > g + 40:
            return match.group(0)  # the coral root keeps its colour in both themes
        token = "--vdot" if b - r > 10 else "--dot"
        return f'style="fill: rgb(var({token}))"'

    svg = re.sub(r'fill="rgb\((\d+),(\d+),(\d+)\)"', recolor, svg)
    return re.sub(r'width="\d+" height="\d+"', 'width="100%" height="100%"', svg, count=1)


def data(setup):
    results = json.load(open(os.path.join(BENCH, "results.json")))
    round1 = json.load(open(os.path.join(BENCH, "results_v1.json")))
    S, C = results["summary"], results["comparisons"]["shipped"]
    by_set = results["comparisons_by_set"]["shipped"]
    side = lambda arm: {"tokens": S[arm]["mean_tokens"], "quality": S[arm]["quality"], "turns": S[arm]["mean_turns"], "cost": S[arm]["mean_cost"]}
    change = lambda c: {"tokens": c["token_change_pct"], "tokensCI": c["token_change_ci95"], "quality": c["quality_delta"], "qualityCI": c["quality_delta_ci95"]}
    rows = results["rows"]
    original = by_set["original"]
    original_ids = {t["id"] for t in json.load(open(os.path.join(BENCH, "tasks.json")))["tasks"] if t.get("set", "original") == "original"}
    original_rows = [r[TREAT] for r in rows if r["task"] in original_ids and TREAT in r]
    used_original, runs_original = sum(r["used_vesalius"] for r in original_rows), sum(r["reps"] for r in original_rows)
    r1 = round1["comparisons"]["shipped"]
    return {
        "base": side(BASE), "ves": side(TREAT), "change": change(C), "heldout": change(by_set["heldout"]),
        "used": S[TREAT]["runs_using_vesalius"], "runs": S[TREAT]["runs"], "tasks": C["tasks"],
        "repos": len({r["repo"] for r in rows}), "claude": setup.get("claude", "2.1.307"), "model": setup.get("model", "claude-opus-5-5"),
        "rounds": [
            {"label": "Round 1 · Vesalius 1", "sub": f"{r1['tasks']} questions × 2 runs", "used": round1["summary"][TREAT]["runs_using_vesalius"],
             "runs": round1["summary"][TREAT]["runs"], **change(r1), "faded": True},
            {"label": "Round 2 · same questions", "sub": f"{original['tasks']} questions × 1 run", "used": used_original, "runs": runs_original, **change(original)},
            {"label": "Round 2 · every question", "sub": f"{C['tasks']} questions × 1 run, 6 codebases", "used": S[TREAT]["runs_using_vesalius"],
             "runs": S[TREAT]["runs"], **change(C)},
        ],
        "icon": "data:image/png;base64," + base64.b64encode(open(os.path.join(ROOT, "Vesalius", "Assets.xcassets", "AppIcon.appiconset", "icon_256.png"), "rb").read()).decode(),
        "mark": mark_svg(),
    }


def render(page, card, theme, out):
    url = f"file://{page}?card={card}&theme={theme}"
    dom = subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--window-size=1400,1200", "--virtual-time-budget=6000", "--dump-dom", url],
                         capture_output=True, text=True).stdout
    width, height = (int(v) for v in re.search(r'data-size="(\d+)x(\d+)"', dom).groups())
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=2", "--default-background-color=00000000",
                    f"--window-size={width},{height}", "--virtual-time-budget=6000", f"--screenshot={out}", url],
                   capture_output=True, check=True)
    print(f"wrote {os.path.relpath(out, ROOT)} ({width * 2}x{height * 2})")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--setup", help="the benchmark's setup.json, for the Claude Code version and model")
    args = parser.parse_args()
    setup = {}
    if args.setup:
        raw = json.load(open(args.setup))
        setup = {"claude": raw["versions"]["claude"].split()[0], "model": raw["model"]}
    html = open(os.path.join(HERE, "cards.html")).read().replace("/*DATA*/null", json.dumps(data(setup)))
    with tempfile.TemporaryDirectory() as work:
        page = os.path.join(work, "cards.html")
        open(page, "w").write(html)
        for card in CARDS:
            for theme in ("dark", "light"):
                render(page, card, theme, os.path.join(HERE, f"{card}-{theme}.png"))


if __name__ == "__main__":
    main()
