"""Lightweight harness instrumentation helpers."""

from __future__ import annotations

import functools
import time
import traceback
from datetime import datetime, timezone
from typing import Any, Callable, Optional, TypeVar

from .client import Synapse

F = TypeVar("F", bound=Callable[..., Any])


def _ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def tool_call(
    synapse: Synapse,
    run_id: str,
    name: Optional[str] = None,
    *,
    agent_id: str = "agent",
    datasource: str = "harness_events",
) -> Callable[[F], F]:
    """Decorator: ingest a tool_call event around a function."""

    def deco(fn: F) -> F:
        tool = name or fn.__name__

        @functools.wraps(fn)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            t0 = time.perf_counter()
            ok = True
            err = None
            try:
                return fn(*args, **kwargs)
            except Exception as e:  # noqa: BLE001 - instrumentation must not hide type
                ok = False
                err = f"{type(e).__name__}: {e}"
                raise
            finally:
                ms = int((time.perf_counter() - t0) * 1000)
                payload: dict[str, Any] = {"name": tool, "ok": ok, "latency_ms": ms}
                if err:
                    payload["error"] = err
                    payload["traceback"] = traceback.format_exc()[-2000:]
                event = {
                    "ts": _ts(),
                    "run_id": run_id,
                    "agent_id": agent_id,
                    "type": "tool_call",
                    "payload": payload,
                }
                try:
                    synapse.ingest(datasource, [event])
                except Exception:
                    pass

        return wrapper  # type: ignore[return-value]

    return deco
