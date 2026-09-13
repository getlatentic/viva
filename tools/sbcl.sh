#!/bin/sh
# Find SBCL and leave it in $sbcl_bin. Sourced, not run:
#
#     . "$root/tools/sbcl.sh"
#     exec "$sbcl_bin" --script ...
#
# A terminal started from a GUI does not read a login profile, so its PATH often
# has no Homebrew in it. `exec sbcl` then fails with `sbcl: not found`, which
# names the shell's problem and not the person's. Looked for the way a person
# would: what they told us, then the PATH, then where a package manager puts it.
sbcl_bin=${VIVA_SBCL:-}

if [ -n "$sbcl_bin" ] && [ ! -x "$sbcl_bin" ]; then
  # A NAMED ONE THAT IS NOT THERE IS AN ERROR, not a reason to go looking. The
  # person said which sbcl to use; running a different one is that ignored.
  printf 'VIVA_SBCL names %s, which is not an executable file.\n' "$sbcl_bin" >&2
  exit 127
fi

if [ -z "$sbcl_bin" ]; then
  if command -v sbcl >/dev/null 2>&1; then
    sbcl_bin=$(command -v sbcl)
  else
    for sbcl_candidate in /opt/homebrew/bin/sbcl /usr/local/bin/sbcl \
                          /usr/bin/sbcl "${HOME:-}/.local/bin/sbcl"
    do
      if [ -x "$sbcl_candidate" ]; then
        sbcl_bin=$sbcl_candidate
        break
      fi
    done
    unset sbcl_candidate
  fi
fi

if [ -z "$sbcl_bin" ]; then
  printf 'viva needs sbcl, and there is none on this PATH.\n\n' >&2
  printf '  PATH=%s\n\n' "$PATH" >&2
  printf 'Install it:   brew install sbcl        (or: apt install sbcl)\n' >&2
  printf 'Or name it:   VIVA_SBCL=/path/to/sbcl viva ...\n' >&2
  exit 127
fi
