# What I have learned working here

- Vivarium trace files (data/*.jsonl) are one JSON object per line: kind is "span" (counts) or "log" (does not, even though it may carry the same fields); a span's elapsed lives at body.span.elapsed as {"value": n, "unit": "ms"|"us"|"s"}, and a span may have no elapsed at all.
