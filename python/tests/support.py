from __future__ import annotations

import json
import subprocess
import sys
import threading
import time

REQ_TIMEOUT = 60.0
KERNEL_TIMEOUT = 120.0


class BridgeProcess:
    """A sidecar subprocess plus helpers for speaking the protocol."""

    def __init__(self, command=None, *, env=None) -> None:
        self.proc = subprocess.Popen(
            command or [sys.executable, "-m", "jove_bridge"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
            env=env,
        )
        self.messages: list = []
        self._cond = threading.Condition()
        self._eof = False
        self._stderr: list[str] = []
        self._next_id = 0
        self._reader_error = None
        self._closed = False
        self._readers = []
        try:
            for target in (self._read_stdout, self._read_stderr):
                reader = threading.Thread(target=target, daemon=True)
                reader.start()
                self._readers.append(reader)
        except BaseException:
            self.close()
            raise

    def _read_stdout(self) -> None:
        assert self.proc.stdout is not None
        try:
            for line in self.proc.stdout:
                try:
                    msg = json.loads(line)
                    if not isinstance(msg, dict):
                        raise ValueError("expected a JSON object")
                except ValueError as exc:
                    raise AssertionError(f"malformed bridge stdout: {line!r}") from exc
                with self._cond:
                    self.messages.append(msg)
                    self._cond.notify_all()
        except Exception as exc:
            with self._cond:
                self._reader_error = exc
        finally:
            with self._cond:
                self._eof = True
                self._cond.notify_all()

    def _read_stderr(self) -> None:
        assert self.proc.stderr is not None
        try:
            for line in self.proc.stderr:
                self._stderr.append(line)
        except Exception as exc:
            with self._cond:
                self._reader_error = exc
                self._cond.notify_all()

    def assert_healthy(self) -> None:
        if self._reader_error is not None:
            raise AssertionError(str(self._reader_error)) from self._reader_error

    def cursor(self) -> int:
        """Snapshot of the message count; use as ``since`` in waiters."""
        return len(self.messages)

    def send(self, obj) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def send_line(self, text: str) -> None:
        """Send a raw (possibly malformed) line."""
        assert self.proc.stdin is not None
        self.proc.stdin.write(text + "\n")
        self.proc.stdin.flush()

    def wait(self, predicate, timeout=REQ_TIMEOUT, since=0):
        """Return the first message matching ``predicate`` from ``since``."""
        deadline = time.monotonic() + timeout
        with self._cond:
            i = since
            while True:
                self.assert_healthy()
                while i < len(self.messages):
                    msg = self.messages[i]
                    i += 1
                    if predicate(msg):
                        return msg
                if self._eof:
                    raise AssertionError(
                        "bridge exited before the expected message; "
                        "stderr tail:\n" + "".join(self._stderr[-30:])
                    )
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(
                        "timed out waiting for a message; messages since "
                        f"{since}:\n"
                        + json.dumps(self.messages[since:], indent=1)[:4000]
                    )
                self._cond.wait(remaining)

    def wait_ready(self, timeout=REQ_TIMEOUT) -> dict:
        msg = self.wait(lambda m: m.get("event") == "ready", timeout)
        assert self.messages[0] is msg, "ready must be the first message"
        return msg

    def send_request(self, method: str, params=None) -> int:
        self._next_id += 1
        self.send({"id": self._next_id, "method": method, "params": params or {}})
        return self._next_id

    def wait_response(self, reply_id, timeout=REQ_TIMEOUT, since=0) -> dict:
        return self.wait(
            lambda m: m.get("id") == reply_id and ("result" in m or "error" in m),
            timeout,
            since,
        )

    def request(self, method: str, params=None, timeout=REQ_TIMEOUT) -> dict:
        since = self.cursor()
        reply_id = self.send_request(method, params)
        return self.wait_response(reply_id, timeout, since)

    def wait_event(self, event, timeout=REQ_TIMEOUT, since=0, pred=None) -> dict:
        def check(msg):
            if msg.get("event") != event:
                return False
            return pred is None or pred(msg.get("params") or {})

        return self.wait(check, timeout, since)

    def wait_status(self, *states, timeout=KERNEL_TIMEOUT, since=0) -> dict:
        return self.wait_event(
            "kernel_status",
            timeout,
            since,
            pred=lambda p: p.get("status") in states,
        )

    def statuses_since(self, since: int) -> list:
        return [
            m["params"]["status"]
            for m in self.messages[since:]
            if m.get("event") == "kernel_status"
        ]

    def outputs_since(self, since: int) -> list:
        return [
            m["params"] for m in self.messages[since:] if m.get("event") == "output"
        ]

    def start_kernel(self, name="python3", timeout=KERNEL_TIMEOUT) -> dict:
        since = self.cursor()
        msg = self.request("start_kernel", {"kernelspec": name}, timeout)
        assert "result" in msg, f"start_kernel failed: {msg}"
        self.wait_status("idle", since=since, timeout=timeout)
        return msg

    def close(self, grace_timeout=15, terminate_timeout=5) -> None:
        if self._closed:
            return
        try:
            if self.proc.stdin is not None and not self.proc.stdin.closed:
                try:
                    self.proc.stdin.close()
                except BrokenPipeError:
                    pass
            try:
                self.proc.wait(timeout=grace_timeout)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=terminate_timeout)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait()
        finally:
            if self.proc.poll() is None:
                self.proc.kill()
                self.proc.wait()
            for reader in self._readers:
                reader.join(timeout=5)
            for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
                if stream is not None and not stream.closed:
                    stream.close()
            self._closed = True
            assert not any(reader.is_alive() for reader in self._readers), (
                "bridge reader did not stop"
            )
