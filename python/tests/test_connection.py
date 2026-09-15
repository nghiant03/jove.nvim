"""Writer lifecycle regressions independent of a real kernel."""

import io
import json
import time

from jove_bridge.__main__ import Connection


def test_close_flushes_queued_messages():
    out = io.StringIO()
    conn = Connection(out)
    for index in range(300):
        conn.send_result(index, {})
    conn.close()
    assert not conn._thread.is_alive()
    assert [json.loads(line)["id"] for line in out.getvalue().splitlines()] == list(
        range(300)
    )


def test_broken_writer_stops_accepting_messages(capsys):
    class BrokenOutput:
        def write(self, _):
            raise BrokenPipeError("closed")

    conn = Connection(BrokenOutput())
    conn.send_result(1, {})
    assert conn._closed.wait(1)
    start = time.monotonic()
    for index in range(1000):
        conn.send_result(index, {})
    conn.close()
    assert time.monotonic() - start < 1
    assert conn._queue.empty()
    assert "writer failed" in capsys.readouterr().err
