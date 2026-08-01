#!/usr/bin/env python3
"""Minimal harness loop against a local Synapse runtime."""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "sdk" / "python"))

from synapse_sdk import Synapse  # noqa: E402
from synapse_sdk.instrument import tool_call  # noqa: E402


def main() -> None:
    s = Synapse("http://127.0.0.1:8787")
    print("health:", s.health())

    run_id = "run_agent_loop"

    @tool_call(s, run_id, "grep")
    def grep(q: str) -> str:
        return f"hits for {q}"

    grep("margin risk")
    print("recall:", json.dumps(s.recall(run_id, query="risk"), indent=2)[:400])
    print("plan:", json.dumps(s.plan("fix risk bug", run_id=run_id), indent=2)[:400])
    print("remember:", s.remember(run_id, "agent loop saw elevated margin risk", confidence=0.88))
    print("embed:", json.dumps(s.pipe("embed_recall", run_id=run_id, query="margin"), indent=2)[:400])


if __name__ == "__main__":
    main()
