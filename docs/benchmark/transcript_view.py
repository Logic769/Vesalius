#!/usr/bin/env python3
"""Prints a compact, numbered timeline of one benchmark transcript: each tool call with its input, the size and
start of its result, and the assistant's text. Subagent events are indented.

Usage: transcript_view.py <transcript.jsonl> [--result-chars 600]
"""
import argparse, json


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    parser.add_argument("--result-chars", type=int, default=600)
    args = parser.parse_args()
    names, step = {}, 0
    for line in open(args.path):
        event = json.loads(line)
        indent = "    " if event.get("parent_tool_use_id") else ""
        if event.get("type") == "assistant":
            usage = event["message"].get("usage", {})
            context = usage.get("input_tokens", 0) + usage.get("cache_read_input_tokens", 0) + usage.get("cache_creation_input_tokens", 0)
            for block in event["message"].get("content", []):
                if block.get("type") == "text" and block["text"].strip():
                    print(f"{indent}[text, context {context:,} tokens] {block['text'][:400]}")
                elif block.get("type") == "tool_use":
                    step += 1
                    names[block["id"]] = block["name"]
                    print(f"{indent}#{step} CALL {block['name']} {json.dumps(block['input'])[:300]}  (context {context:,} tokens)")
        elif event.get("type") == "user":
            content = event["message"].get("content")
            if isinstance(content, list):
                for block in content:
                    if block.get("type") == "tool_result":
                        text = block.get("content")
                        text = text if isinstance(text, str) else json.dumps(text)
                        print(f"{indent}   RESULT of {names.get(block.get('tool_use_id'), '?')}: {len(text):,} chars: {text[:args.result_chars]!r}")
        elif event.get("type") == "result":
            print(f"RESULT EVENT: turns={event.get('num_turns')} cost=${event.get('total_cost_usd', 0):.3f}")


if __name__ == "__main__":
    main()
