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

Install:

```bash
pip install -e .
```
