#!/usr/bin/env python3
"""A very small expect(1) for driving a QEMU serial console.

Nothing here is clever: it starts QEMU with the serial port on stdio, reads
whatever the guest prints, waits for regexes and types lines back.  That is
enough to assert "the system booted and these commands produced these
answers" without a human watching, which is the only way a build this long
can be verified at all.

  usage: qemu_expect.py --script FILE [--timeout SEC] [--log FILE] -- QEMU...

Script directives, one per line (# starts a comment):

  TIMEOUT <sec>     per-step timeout for the steps that follow
  EXPECT  <regex>   wait until the guest prints something matching
  SEND    <text>    type text plus newline into the guest
  FAIL    <regex>   abort immediately if this ever appears
  SLEEP   <sec>     wait

Exit status: 0 all steps passed, 1 a step failed or a FAIL pattern matched,
2 the harness itself broke.
"""

import argparse
import os
import re
import select
import signal
import subprocess
import sys
import time

RESET, RED, GREEN, DIM = "\033[0m", "\033[1;31m", "\033[1;32m", "\033[2m"
if not sys.stdout.isatty():
    RESET = RED = GREEN = DIM = ""


def note(msg):
    print(f"{DIM}[expect]{RESET} {msg}", flush=True)


class Session:
    def __init__(self, argv, logfile, echo):
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0,
        )
        self.buf = ""
        self.log = open(logfile, "wb") if logfile else None
        self.echo = echo
        self.fails = []

    def _drain(self, timeout):
        """Read whatever is available, up to `timeout` seconds."""
        fd = self.proc.stdout.fileno()
        ready, _, _ = select.select([fd], [], [], timeout)
        if not ready:
            return False
        chunk = os.read(fd, 65536)
        if not chunk:
            return False
        if self.log:
            self.log.write(chunk)
            self.log.flush()
        if self.echo:
            sys.stdout.write(chunk.decode("utf-8", "replace"))
            sys.stdout.flush()
        self.buf += chunk.decode("utf-8", "replace")
        return True

    def _check_fails(self):
        for pat in self.fails:
            m = pat.search(self.buf)
            if m:
                raise AssertionError(f"failure pattern matched: {pat.pattern!r} -> {m.group(0)!r}")

    def expect(self, pattern, timeout):
        # Serial output is one accumulated buffer.  Test-script anchors are
        # intended to address individual console lines, not only the start
        # and end of the entire boot transcript.
        rx = re.compile(pattern, re.MULTILINE)
        deadline = time.time() + timeout
        while True:
            m = rx.search(self.buf)
            if m:
                self.buf = self.buf[m.end():]
                return m
            self._check_fails()
            if self.proc.poll() is not None:
                raise AssertionError(
                    f"qemu exited with {self.proc.returncode} while waiting for {pattern!r}"
                )
            left = deadline - time.time()
            if left <= 0:
                tail = self.buf[-1200:].replace("\r", "")
                raise AssertionError(
                    f"timed out after {timeout}s waiting for {pattern!r}\n"
                    f"--- last output ---\n{tail}\n-------------------"
                )
            self._drain(min(left, 0.5))

    def send(self, text):
        self.proc.stdin.write((text + "\n").encode())
        self.proc.stdin.flush()

    def close(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if self.log:
            self.log.close()


def parse_script(path):
    steps = []
    with open(path) as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split(None, 1)
            verb = parts[0].upper()
            arg = parts[1] if len(parts) > 1 else ""
            if verb not in {"EXPECT", "SEND", "FAIL", "SLEEP", "TIMEOUT"}:
                sys.exit(f"{path}:{lineno}: unknown directive {verb!r}")
            steps.append((verb, arg, lineno))
    return steps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", required=True)
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--log")
    ap.add_argument("--echo", action="store_true", help="mirror guest output")
    ap.add_argument("qemu", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    qemu = args.qemu[1:] if args.qemu and args.qemu[0] == "--" else args.qemu
    if not qemu:
        sys.exit("no qemu command given")

    steps = parse_script(args.script)
    step_timeout = args.timeout
    session = Session(qemu, args.log, args.echo)
    started = time.time()
    passed = 0

    try:
        for verb, arg, lineno in steps:
            if verb == "TIMEOUT":
                step_timeout = float(arg)
            elif verb == "FAIL":
                session.fails.append(re.compile(arg, re.MULTILINE))
            elif verb == "SLEEP":
                time.sleep(float(arg))
            elif verb == "SEND":
                note(f"send: {arg}")
                session.send(arg)
            elif verb == "EXPECT":
                note(f"wait: {arg}")
                session.expect(arg, step_timeout)
                passed += 1
                note(f"{GREEN}ok{RESET}   {arg}")
    except AssertionError as exc:
        note(f"{RED}FAILED{RESET} at line {lineno}: {exc}")
        session.close()
        return 1
    except KeyboardInterrupt:
        session.close()
        return 2

    session.close()
    note(f"{GREEN}all {passed} expectations met{RESET} in {time.time() - started:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
