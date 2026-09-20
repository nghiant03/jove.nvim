"""Kernel lifecycle management (a thin jupyter_client wrapper).

The bridge owns exactly one kernel per process. This module
knows nothing about the wire protocol; it raises :class:`KernelError` with a
protocol error code and lets the caller translate.
"""

from __future__ import annotations

import time
from typing import Any, Optional

from jupyter_client.kernelspec import KernelSpecManager
from jupyter_client.manager import KernelManager

# Seconds to wait for a kernel to exit on shutdown before killing it.
SHUTDOWN_GRACE = 5.0


class KernelError(Exception):
    """Error carrying a protocol error code."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class KernelController:
    """Owns the single KernelManager/kernel client of this bridge process."""

    def __init__(self) -> None:
        self._specs = KernelSpecManager()
        self.km: Optional[KernelManager] = None
        self.client: Any = None

    @property
    def running(self) -> bool:
        return self.client is not None

    def require_client(self) -> Any:
        if self.client is None:
            raise KernelError("kernel_not_running", "start a kernel first")
        return self.client

    def require_km(self) -> KernelManager:
        if self.km is None:
            raise KernelError("kernel_not_running", "start a kernel first")
        return self.km

    def list_kernelspecs(self) -> dict:
        specs = {}
        for name, info in self._specs.get_all_specs().items():
            spec = info.get("spec") or {}
            specs[name] = {
                "display_name": str(spec.get("display_name") or name),
                "language": str(spec.get("language") or ""),
            }
        return specs

    def require_kernelspec(self, kernelspec: str) -> None:
        """Raise ``kernelspec_not_found`` unless the spec exists."""
        if kernelspec not in self.list_kernelspecs():
            raise KernelError(
                "kernelspec_not_found", f"no such kernelspec: {kernelspec!r}"
            )

    def start(self, kernelspec: str) -> Any:
        """Start the kernel; returns the started kernel client."""
        self.require_kernelspec(kernelspec)
        if self.km is not None:
            self.shutdown()
        km = KernelManager(kernel_name=kernelspec)
        try:
            km.start_kernel()
        except Exception as exc:
            raise KernelError(
                "kernel_start_failed",
                f"failed to start kernel {kernelspec!r}: {exc}",
            ) from exc
        client = km.client()
        try:
            client.start_channels(shell=True, iopub=True, stdin=False, hb=False)
        except Exception as exc:
            self._kill_quiet(km)
            raise KernelError(
                "kernel_start_failed",
                f"failed to open kernel channels: {exc}",
            ) from exc
        self.km = km
        self.client = client
        return client

    def interrupt(self) -> None:
        km = self.require_km()
        km.interrupt_kernel()

    def restart(self) -> None:
        self.require_km().restart_kernel()

    def shutdown(self, grace: float = SHUTDOWN_GRACE) -> None:
        """Stop the kernel: request shutdown, wait ``grace`` seconds, kill."""
        km, client = self.km, self.client
        self.km = None
        self.client = None
        if km is None:
            return
        if client is not None:
            try:
                client.stop_channels()
            except Exception:
                pass
        try:
            # No `block` kwarg: jupyter_client >= 8 removed it (and this module
            # pins >= 8). The default sends a polite shutdown request that an
            # idle kernel honors within milliseconds, keeping the grace loop
            # below a rare fallback rather than the common path.
            km.shutdown_kernel(restart=False)
        except Exception:
            pass
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            try:
                if not km.is_alive():
                    return
            except Exception:
                return
            time.sleep(0.05)
        self._kill_quiet(km)

    def mark_dead(self) -> None:
        """The kernel process died on its own; drop it without killing."""
        km, client = self.km, self.client
        self.km = None
        self.client = None
        if client is not None:
            try:
                client.stop_channels()
            except Exception:
                pass
        if km is not None:
            self._kill_quiet(km)

    @staticmethod
    def _kill_quiet(km: KernelManager) -> None:
        # jupyter_client < 7 exposes ``kill_kernel``; 7+ names it ``_kill_kernel``.
        kill = getattr(km, "kill_kernel", None) or getattr(km, "_kill_kernel", None)
        if kill is None:
            return
        try:
            kill()
        except Exception:
            pass
