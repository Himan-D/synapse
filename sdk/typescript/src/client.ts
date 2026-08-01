export type Json = null | boolean | number | string | Json[] | { [k: string]: Json };

export class Synapse {
  constructor(
    public baseUrl = "http://127.0.0.1:8787",
    public token?: string,
  ) {
    this.baseUrl = baseUrl.replace(/\/$/, "");
  }

  private headers(contentType?: string): Record<string, string> {
    const h: Record<string, string> = {};
    if (contentType) h["Content-Type"] = contentType;
    if (this.token) h.Authorization = `Bearer ${this.token}`;
    return h;
  }

  private async request(
    method: string,
    path: string,
    opts: { query?: Record<string, string | number | undefined>; body?: string; contentType?: string } = {},
  ): Promise<Json> {
    const url = new URL(this.baseUrl + path);
    if (opts.query) {
      for (const [k, v] of Object.entries(opts.query)) {
        if (v !== undefined && v !== "") url.searchParams.set(k, String(v));
      }
    }
    const res = await fetch(url, {
      method,
      headers: this.headers(opts.contentType),
      body: opts.body,
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`Synapse ${method} ${path} failed: ${res.status} ${text}`);
    return text ? (JSON.parse(text) as Json) : null;
  }

  health() {
    return this.request("GET", "/health");
  }
  workspace() {
    return this.request("GET", "/v1/workspace");
  }
  endpoints() {
    return this.request("GET", "/v1/endpoints");
  }
  recall(runId: string, query = "") {
    return this.request("GET", "/v1/recall", { query: { run_id: runId, query } });
  }
  plan(goal: string, runId = "") {
    return this.request("GET", "/v1/plan", { query: { goal, run_id: runId } });
  }
  route(query: string, runId = "") {
    return this.request("GET", "/v1/route", { query: { query, run_id: runId } });
  }
  impact(runId: string, nodeId = "") {
    return this.request("GET", "/v1/impact", { query: { run_id: runId, node_id: nodeId } });
  }
  metrics(runId = "") {
    return this.request("GET", "/v1/metrics/tool_failure_rate", { query: { run_id: runId } });
  }
  dispute(runId = "") {
    return this.request("GET", "/v1/dispute", { query: { run_id: runId } });
  }
  embed(runId: string, query: string, limit = 8) {
    return this.request("GET", "/v1/embed", { query: { run_id: runId, query, limit } });
  }
  graph(runId = "") {
    return this.request("GET", "/v1/graph", { query: { run_id: runId } });
  }
  consolidate(runId = "") {
    return this.request("GET", "/v1/consolidate", { query: { run_id: runId } });
  }
  remember(runId: string, text: string, confidence = 0.9, agentId = "agent") {
    return this.request("POST", "/v1/remember", {
      contentType: "application/json",
      body: JSON.stringify({ run_id: runId, text, confidence, agent_id: agentId }),
    });
  }
  query(datasource: string, where: Record<string, string> = {}, limit = 100, offset = 0) {
    return this.request("POST", "/v1/query", {
      contentType: "application/json",
      body: JSON.stringify({ datasource, where, limit, offset }),
    });
  }
}
