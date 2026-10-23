#!/usr/bin/env python3
"""Collects judge grades from one or more grading-workflow journals into grades.json: {answer id: [grade, ...]}.

Usage: extract_grades.py <out grades.json> <journal.jsonl> [<journal.jsonl> ...]
"""
import json, sys

out, journals = sys.argv[1], sys.argv[2:]
grades, panels = {}, 0
for journal in journals:  # in order: a later journal that re-grades answers replaces their earlier grades
    labels, fresh = {}, {}
    for line in open(journal):
        event = json.loads(line)
        if event["type"] == "started":
            labels[event["key"]] = event["label"]
        elif event["type"] == "result" and labels.get(event["key"], "").startswith("judge:") and isinstance(event.get("result"), dict):
            panels += 1
            for grade in event["result"].get("grades", []):
                fresh.setdefault(grade["id"], []).append(grade)
    grades.update(fresh)
json.dump(grades, open(out, "w"), indent=1)
counts = {}
for g in grades.values():
    counts[len(g)] = counts.get(len(g), 0) + 1
print(f"{panels} panels, {len(grades)} answers graded; judges per answer: {counts}")
