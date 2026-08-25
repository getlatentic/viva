#!/bin/sh
# Does terminal-size read the REAL size?
#
# It cannot be checked from an ordinary test run: a test suite has no
# controlling terminal, so the function returns its fallback and a broken
# ioctl looks identical to a working one. So: make a pty, set it to a size
# nothing would produce by accident, and make the function say it back.
#
# This exists because the first binding here was wrong in a way that passed
# every test -- a fixed-arity alien declaration for a variadic C function,
# which on arm64 Darwin returns -1 and leaves a plausible number in the struct.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
rows=${1:-37}
columns=${2:-113}

python3 - "$root" "$rows" "$columns" <<'PY'
import os, pty, fcntl, termios, struct, sys, select

root, rows, columns = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
load = f'''(progn
(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(push #p"{root}/" asdf:*central-registry*)
(handler-bind ((warning #'muffle-warning)) (ql:quickload "viva/tui" :silent t)))'''

# A separate --eval, because a form is READ in full before it is evaluated and
# the package does not exist until the one above has run.
report = '''(let ((size (funcall (read-from-string "viva.tui:terminal-size"))))
  (format t "~&SIZE ~d ~d~%" (car size) (cdr size)))'''

pid, fd = pty.fork()
if pid == 0:
    os.execvp("sbcl", ["sbcl", "--noinform", "--non-interactive",
                        "--eval", load, "--eval", report])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
out = b""
while True:
    try:
        r, _, _ = select.select([fd], [], [], 300)
        if not r:
            break
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        out += chunk
    except OSError:
        break
os.waitpid(pid, 0)
text = out.decode(errors="replace")
line = next((l for l in text.splitlines() if l.startswith("SIZE ")), None)
if line is None:
    print(text[-2000:])
    sys.exit("no size reported -- the program did not get that far")
got = tuple(int(n) for n in line.split()[1:3])
print(f"pty set to {rows}x{columns}; terminal-size said {got[0]}x{got[1]}")
if got != (rows, columns):
    sys.exit("MISMATCH -- terminal-size is not reading the terminal")
print("ok")
PY
