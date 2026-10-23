#!/usr/bin/env python3
"""Collects the final (challenged) answer keys from a workflow journal into answer_keys.json."""
import json, sys

journal, out = sys.argv[1], sys.argv[2]
labels, keys = {}, {}
for line in open(journal):
    event = json.loads(line)
    if event["type"] == "started":
        labels[event["key"]] = event["label"]
    elif event["type"] == "result" and labels.get(event["key"], "").startswith("challenge:") and isinstance(event.get("result"), dict):
        key = event["result"]
        key["task"] = labels[event["key"]].split(":", 1)[1]
        keys[key["task"]] = key
json.dump([keys[t] for t in sorted(keys)], open(out, "w"), indent=1)
print(f"{len(keys)} final keys: {sorted(keys)}")
