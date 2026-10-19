#!/usr/bin/env python3
# pty-drive.py <transcript> <rules.json> -- <cmd> [args...]
#
# Runs <cmd> on a real PTY (so the kernel line discipline echoes typed bytes,
# exactly like a terminal) and answers each prompt from rules.json:
# [[regex, reply], ...], first match on the output since the last reply wins,
# no match replies with a bare Enter. Everything the terminal showed is written
# to <transcript>. Exit status is the child's.
import json
import os
import pty
import re
import select
import sys
import time

transcript, rules_file = sys.argv[1], sys.argv[2]
cmd = sys.argv[sys.argv.index('--') + 1:]
rules = [(re.compile(r), reply) for r, reply in json.load(open(rules_file))]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)

buf = b''
log = open(transcript, 'wb')
deadline = time.time() + 120
status = 1
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if not r:
        try:
            done, st = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            break
        if done:
            status = os.waitstatus_to_exitcode(st)
            break
        continue
    try:
        data = os.read(fd, 65536)
    except OSError:
        data = b''
    if not data:
        break
    log.write(data)
    log.flush()
    buf += data
    text = buf.decode('utf-8', 'replace')
    if text.endswith(('> ', '[Y/n] ', 'skip): ')):
        reply = ''
        for rx, rep in rules:
            if rx.search(text):
                reply = rep
                break
        os.write(fd, (reply + '\r').encode())
        buf = b''
else:
    os.kill(pid, 9)
    log.write(b'\n[pty-drive: timeout]\n')

try:
    _, st = os.waitpid(pid, 0)
    status = os.waitstatus_to_exitcode(st)
except ChildProcessError:
    pass
log.close()
sys.exit(status if status >= 0 else 1)
