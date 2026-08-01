"""Tinybird-style pipe authoring helpers that emit Synapse .pipe.json files."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Mapping, Sequence


def define_pipe(
    name: str,
    nodes: Sequence[Mapping[str, Any]],
    *,
    pipe_type: str = "endpoint",
    endpoint_path: str | None = None,
    params: Sequence[str] | None = None,
    description: str | None = None,
    target_datasource: str | None = None,
    sink_path: str | None = None,
) -> dict[str, Any]:
    doc: dict[str, Any] = {"name": name, "type": pipe_type, "nodes": list(nodes)}
    if description:
        doc["description"] = description
    if target_datasource:
        doc["target_datasource"] = target_datasource
    if sink_path:
        doc["sink_path"] = sink_path
    if endpoint_path:
        doc["endpoint"] = {"path": endpoint_path, "params": list(params or [])}
    return doc


def write_pipe(root: str | Path, pipe: Mapping[str, Any]) -> Path:
    root = Path(root)
    pipes = root / "pipes"
    pipes.mkdir(parents=True, exist_ok=True)
    path = pipes / f"{pipe['name']}.pipe.json"
    path.write_text(json.dumps(pipe, indent=2) + "\n", encoding="utf-8")
    return path


def filter_node(datasource: str, **where: str) -> dict[str, Any]:
    return {"type": "filter", "datasource": datasource, "where": where}


def materialize_node(*layers: str) -> dict[str, Any]:
    return {"type": "materialize_graph", "layers": list(layers)}


def project_node(op: str, **extra: Any) -> dict[str, Any]:
    node: dict[str, Any] = {"type": "project", "op": op}
    node.update(extra)
    return node
