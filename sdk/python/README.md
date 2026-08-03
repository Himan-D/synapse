# synapse-sdk

Thin HTTP client for a local or remote Synapse runtime.

```python
from synapse_sdk import Synapse

s = Synapse("http://127.0.0.1:8787", token=None)
s.health()
s.workspace()
s.recall("run_demo", query="risk")
s.plan("fix risk bug", run_id="run_demo")
s.route("run tests", run_id="run_demo")
s.dispute("run_demo")
s.remember("run_demo", "margin risk is elevated", confidence=0.9)
```

Against hosted Synapse, pass the workspace id and its token. Every verb is then
routed to `/v1/w/{workspace_id}/…`:

```python
s = Synapse("https://synapse.example.com", token="p.…", workspace_id="ws_…")
s.recall("run_demo", query="risk")   # GET /v1/w/ws_…/recall
```

Install:

```bash
pip install -e .
```
