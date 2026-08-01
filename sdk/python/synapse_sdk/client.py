from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any, Iterable, Mapping, Optional


class Synapse:
    """HTTP client for a local or remote Synapse runtime."""

    def __init__(self, base_url: str = "http://127.0.0.1:8787", token: Optional[str] = None):
        self.base_url = base_url.rstrip("/")
        self.token = token

    def _headers(self, content_type: Optional[str] = None) -> dict[str, str]:
        h: dict[str, str] = {}
        if content_type:
            h["Content-Type"] = content_type
        if self.token:
            h["Authorization"] = f"Bearer {self.token}"
        return h

    def _request(
        self,
        method: str,
        path: str,
        *,
        query: Optional[Mapping[str, Any]] = None,
        body: Optional[bytes] = None,
        content_type: Optional[str] = None,
    ) -> Any:
        url = f"{self.base_url}{path}"
        if query:
            url += "?" + urllib.parse.urlencode({k: v for k, v in query.items() if v is not None})
        req = urllib.request.Request(url, data=body, method=method, headers=self._headers(content_type))
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Synapse {method} {path} failed: {e.code} {detail}") from e

    def health(self) -> dict:
        return self._request("GET", "/health")

    def workspace(self) -> dict:
        return self._request("GET", "/v1/workspace")

    def ingest(self, datasource: str, events: Iterable[Mapping[str, Any]]) -> dict:
        lines = "\n".join(json.dumps(e, separators=(",", ":")) for e in events) + "\n"
        return self._request(
            "POST",
            f"/v1/events/{datasource}",
            body=lines.encode("utf-8"),
            content_type="application/x-ndjson",
        )

    def remember(
        self,
        run_id: str,
        text: str,
        *,
        agent_id: str = "agent",
        confidence: float = 0.9,
    ) -> dict:
        payload = {
            "run_id": run_id,
            "agent_id": agent_id,
            "text": text,
            "confidence": confidence,
        }
        return self._request(
            "POST",
            "/v1/remember",
            body=json.dumps(payload).encode("utf-8"),
            content_type="application/json",
        )

    def recall(self, run_id: str, query: str = "", **extra: Any) -> dict:
        return self._request("GET", "/v1/recall", query={"run_id": run_id, "query": query, **extra})

    def plan(self, goal: str, run_id: str = "", **extra: Any) -> dict:
        return self._request("GET", "/v1/plan", query={"goal": goal, "run_id": run_id, **extra})

    def route(self, query: str, run_id: str = "", **extra: Any) -> dict:
        return self._request("GET", "/v1/route", query={"query": query, "run_id": run_id, **extra})

    def impact(self, run_id: str, node_id: str = "", **extra: Any) -> dict:
        return self._request("GET", "/v1/impact", query={"run_id": run_id, "node_id": node_id, **extra})

    def metrics(self, run_id: str = "", **extra: Any) -> dict:
        return self._request("GET", "/v1/metrics/tool_failure_rate", query={"run_id": run_id, **extra})

    def dispute(self, run_id: str = "", **extra: Any) -> dict:
        return self._request("GET", "/v1/dispute", query={"run_id": run_id, **extra})

    def tool_call_event(
        self,
        run_id: str,
        name: str,
        *,
        ok: bool = True,
        agent_id: str = "agent",
        **payload: Any,
    ) -> dict:
        """Helper to build a tool_call envelope."""
        return {
            "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "run_id": run_id,
            "agent_id": agent_id,
            "type": "tool_call",
            "payload": {"name": name, "ok": ok, **payload},
        }
