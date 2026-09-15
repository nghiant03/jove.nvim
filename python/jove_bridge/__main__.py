"""Entry point: ``python -m jove_bridge``.

Reads newline-delimited JSON requests on stdin, writes newline-delimited
responses and events on stdout (PROTOCOL.md). Runs entirely on the main
thread plus one channel-poll worker thread — no asyncio.
"""

from __future__ import annotations

import json
import queue
import signal
import sys
import threading
from typing import Any, Optional

from . import __version__
from .kernel import KernelError
from .session import DEFERRED, BridgeSession


class Connection:
    """Thread-safe JSON-lines writer backed by a queue and a writer thread."""

    def __init__(self, out: Any) -> None:
        self._out = out
        self._queue: queue.Queue[Any] = queue.Queue(maxsize=256)
        self._closed = threading.Event()
        self._thread = threading.Thread(
            target=self._writer, name="jove-bridge-writer", daemon=True
        )
        self._thread.start()

    def _writer(self) -> None:
        while True:
            try:
                item = self._queue.get(timeout=0.1)
            except queue.Empty:
                if self._closed.is_set():
                    break
                continue
            try:
                self._out.write(json.dumps(item) + "\n")
                self._out.flush()
            except Exception as exc:
                self._closed.set()
                print(f"jove bridge writer failed: {exc}", file=sys.stderr)
                # Release retained payloads; producers stop queueing below.
                while True:
                    try:
                        self._queue.get_nowait()
                    except queue.Empty:
                        break
                break

    def send(self, msg: dict) -> None:
        while not self._closed.is_set():
            try:
                self._queue.put(msg, timeout=0.1)
                return
            except queue.Full:
                continue  # bounded backpressure while the writer drains

    def send_event(self, event: str, params: dict) -> None:
        self.send({"event": event, "params": params})

    def send_result(self, reply_id: int, result: dict) -> None:
        self.send({"id": reply_id, "result": result})

    def send_error(self, reply_id: int, code: str, message: str) -> None:
        self.send({"id": reply_id, "error": {"code": code, "message": message}})

    def close(self, timeout: float = 5.0) -> None:
        """Flush pending messages and stop the writer thread."""
        self._closed.set()
        self._thread.join(timeout)


class _Shutdown(Exception):
    """Raised from a signal handler to unwind the stdin read loop."""


def _handle_line(conn: Connection, session: BridgeSession, line: str) -> bool:
    """Dispatch one line; returns True when the bridge should exit."""
    try:
        req = json.loads(line)
    except ValueError as exc:
        conn.send_event("protocol_error", {"error": f"invalid JSON: {exc}"})
        return False
    if (
        not isinstance(req, dict)
        or not isinstance(req.get("id"), int)
        or isinstance(req.get("id"), bool)
        or not isinstance(req.get("method"), str)
    ):
        conn.send_event(
            "protocol_error",
            {
                "error": "request must be an object with an integer 'id' "
                "and a string 'method'"
            },
        )
        return False
    reply_id, method = req["id"], req["method"]
    params = req.get("params")
    if params is None:
        params = {}
    try:
        result = session.dispatch(method, params, reply_id)
    except KernelError as exc:
        conn.send_error(reply_id, exc.code, exc.message)
        return False
    except Exception as exc:  # never let one request kill the bridge
        conn.send_error(reply_id, "internal_error", f"{type(exc).__name__}: {exc}")
        return False
    if result is not DEFERRED:
        conn.send_result(reply_id, result)
    return method == "shutdown"


def main(stdin: Optional[Any] = None, stdout: Optional[Any] = None) -> int:
    conn = Connection(stdout if stdout is not None else sys.stdout)
    conn.send_event("ready", {"protocol": 1, "version": __version__})
    session = BridgeSession(conn)
    poller = threading.Thread(
        target=session.poll_forever, name="jove-bridge-poll", daemon=True
    )
    poller.start()

    stop = threading.Event()

    def _on_signal(signum: int, frame: Any) -> None:
        if stop.is_set():
            return  # cleanup already started; do not unwind from here
        stop.set()
        raise _Shutdown()

    try:
        old_int = signal.signal(signal.SIGINT, _on_signal)
        old_term = signal.signal(signal.SIGTERM, _on_signal)
    except ValueError:
        old_int = old_term = None  # not on the main thread (e.g. tests)

    stream = stdin if stdin is not None else sys.stdin
    try:
        for raw in stream:
            line = raw.strip()
            if not line:
                continue
            if _handle_line(conn, session, line):
                break
            if stop.is_set():
                break
    except (_Shutdown, KeyboardInterrupt):
        pass
    finally:
        stop.set()
        session.stop()
        try:
            session.shutdown_kernel()
        except BaseException:
            pass
        try:
            poller.join(timeout=2.0)
        except BaseException:
            pass
        try:
            conn.close()
        except BaseException:
            pass
        for signum, handler in (
            (signal.SIGINT, old_int),
            (signal.SIGTERM, old_term),
        ):
            if handler is not None:
                try:
                    signal.signal(signum, handler)
                except (ValueError, OSError):
                    pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
