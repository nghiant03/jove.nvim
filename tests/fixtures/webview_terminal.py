"""Tiny raw-mode PTY peer for webview terminal integration tests."""

import json
import os
import signal
import sys
import tty

tty.setraw(0)


def record(event):
    with open(sys.argv[1], "a", encoding="utf-8") as stream:
        stream.write(json.dumps(event) + "\n")


def draw(*_):
    cols, rows = os.get_terminal_size(0)
    record({"size": [cols, rows]})
    # The graphics sink is stubbed by the test; only framing is under test here.
    os.write(
        1, f"\x1b_Ga=T,t=d,f=32,s={cols * 10},v={rows * 20},i=1,m=0;AAAA\x1b\\".encode()
    )


signal.signal(signal.SIGWINCH, draw)
os.write(1, b"\x1b[?1049h\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[?25l")
draw()
while True:
    data = os.read(0, 4096)
    if not data:
        break
    record({"input": data.hex()})
