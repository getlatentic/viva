from src.text import slugify
cases = [("Hello World", "hello-world"), ("  Trim  Me  ", "trim-me"),
         ("Already-Slugged", "already-slugged"), ("Punctuation! Here?", "punctuation-here"),
         ("multiple   spaces", "multiple-spaces")]
bad = [f"slugify({t!r}) == {slugify(t)!r}, expected {e!r}" for t, e in cases if slugify(t) != e]
print("\n".join(bad) or "OK")
raise SystemExit(1 if bad else 0)
