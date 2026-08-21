# What I have learned working here

- data/ in this workspace holds JSONL traces: records have kind "span" or "log" (a log carries an elapsed value too but is never a span); a span's elapsed is body.span.elapsed as {"value": n, "unit": "ms"|"us"|"s"}, us rounds DOWN to whole ms, s = 1000 ms, missing elapsed counts as 0.
