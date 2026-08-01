# @himand/synapse-sdk

TypeScript client for a local or remote Synapse runtime.

```ts
import { Synapse } from "./src/client.ts";

const s = new Synapse("http://127.0.0.1:8787");
await s.recall("run_demo", "risk");
await s.plan("fix risk bug", "run_demo");
await s.embed("run_demo", "margin");
```
