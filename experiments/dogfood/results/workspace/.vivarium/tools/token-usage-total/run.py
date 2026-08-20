#!/usr/bin/env python3
"""Sum token usage across agent-run JSONL transcripts.

Reads one JSON object of arguments on stdin (optional key "dir", default
"data"). Keeps only message entries whose payload.role is "assistant" and
that carry payload.usage; absent token fields count as zero. Prints a JSON
object {"hit": ..., "miss": ..., "out": ...}.
"""
import glob
import json
import os
import sys

args = json.load(sys.stdin)
directory = args.get("dir", "data")

hit = miss = out = 0
for path in sorted(glob.glob(os.path.join(directory, "*.jsonl"))):
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            entry = json.loads(line)
            if entry.get("kind") != "message":
                continue
            payload = entry.get("payload", {})
            if payload.get("role") != "assistant":
                continue
            usage = payload.get("usage")
            if usage is None:
                continue
            hit += usage.get("prompt_cache_hit_tokens", 0)
            miss += usage.get("prompt_cache_miss_tokens", 0)
            out += usage.get("completion_tokens", 0)

print(json.dumps({"hit": hit, "miss": miss, "out": out}))
