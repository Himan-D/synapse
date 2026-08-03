# @himand/synapse-sdk

TypeScript client for a local or remote Synapse runtime.

```ts
import { Synapse } from "./src/client.ts";

const s = new Synapse("http://127.0.0.1:8787");
await s.recall("run_demo", "risk");
await s.plan("fix risk bug", "run_demo");
await s.embed("run_demo", "margin");
```

Against hosted Synapse, pass the workspace id and its token. Every verb is then
routed to `/v1/w/{workspaceId}/…`:

```ts
const cloud = new Synapse("https://synapse.example.com", "p.…", "ws_…");
await cloud.recall("run_demo", "risk"); // GET /v1/w/ws_…/recall
```
