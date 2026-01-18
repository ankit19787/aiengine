#!/bin/bash
set -e

echo "🚀 Adding Production Hardening + Product Polish..."

cd ai-engine

# -------------------------
# A️⃣ PRODUCTION HARDENING
# -------------------------

# Usage tracking
cat > apps/api/src/middleware/usage.ts <<'EOF'
const USAGE = new Map()

export function trackUsage(req, reply, done) {
  const key = req.headers.authorization || "anonymous"
  USAGE.set(key, (USAGE.get(key) || 0) + 1)
  done()
}

export function getUsage(key: string) {
  return USAGE.get(key) || 0
}
EOF

# Workspace extraction
cat > apps/api/src/middleware/workspace.ts <<'EOF'
export function workspaceContext(req, reply, done) {
  req.workspaceId = req.headers["x-workspace-id"] || "default"
  done()
}
EOF

# Update server with new middleware
cat > apps/api/src/server.ts <<'EOF'
import Fastify from "fastify"
import { chatRoute } from "./routes/chat"
import { authAndRateLimit } from "./middleware/security"
import { trackUsage } from "./middleware/usage"
import { workspaceContext } from "./middleware/workspace"

const app = Fastify({ logger: true })

app.addHook("preHandler", authAndRateLimit)
app.addHook("preHandler", workspaceContext)
app.addHook("preHandler", trackUsage)

app.register(chatRoute, { prefix: "/chat" })

app.listen({ port: 3001 }, () => {
  console.log("API running on http://localhost:3001")
})
EOF

# -------------------------
# Audit logging
# -------------------------
cat > packages/engine/src/audit.ts <<'EOF'
export function audit(event: any) {
  console.log("[AUDIT]", JSON.stringify(event))
}
EOF

# Inject audit into engine
cat > packages/engine/src/engine.ts <<'EOF'
import { agentLoop } from "../../agent/src/agent"
import { searchEmbedding } from "../../context/src/rag"
import { audit } from "./audit"

export async function* runEngine(input) {
  audit({ type: "request", input })

  const ragContext = await searchEmbedding(input.userMessage)

  for await (const chunk of agentLoop({
    ...input,
    ragContext
  })) {
    audit({ type: "response_chunk", chunk })
    yield chunk
  }
}
EOF

# -------------------------
# B️⃣ PRODUCT POLISH (UI + API)
# -------------------------

# Repo ingestion API
cat > apps/api/src/routes/ingest.ts <<'EOF'
import { ingestRepo } from "../../../packages/context/src/ingest"

export async function ingestRoute(app) {
  app.post("/", async (req, reply) => {
    const { repoUrl } = req.body
    const result = await ingestRepo(repoUrl)
    return result
  })
}
EOF

# Register ingest route
sed -i '' 's/app.register(chatRoute/app.register(ingestRoute, { prefix: "\/ingest" })\napp.register(chatRoute/' apps/api/src/server.ts || true

# -------------------------
# Web UI polish
# -------------------------
cat > apps/web/app/page.tsx <<'EOF'
"use client"
import { useState } from "react"

export default function Page() {
  const [input, setInput] = useState("")
  const [output, setOutput] = useState("")
  const [repo, setRepo] = useState("")

  async function send() {
    const res = await fetch("http://localhost:3001/chat", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer dev",
        "x-workspace-id": "default"
      },
      body: JSON.stringify({ message: input })
    })

    const reader = res.body.getReader()
    const decoder = new TextDecoder()

    setOutput("")
    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      setOutput(o => o + decoder.decode(value))
    }
  }

  async function ingest() {
    await fetch("http://localhost:3001/ingest", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer dev"
      },
      body: JSON.stringify({ repoUrl: repo })
    })
    alert("Repo ingested")
  }

  return (
    <div style={{ padding: 20 }}>
      <h2>AI Engine</h2>

      <input
        placeholder="GitHub repo URL"
        value={repo}
        onChange={e => setRepo(e.target.value)}
      />
      <button onClick={ingest}>Ingest Repo</button>

      <hr />

      <textarea
        rows={5}
        placeholder="Ask something..."
        value={input}
        onChange={e => setInput(e.target.value)}
      />
      <br />
      <button onClick={send}>Send</button>

      <pre>{output}</pre>
    </div>
  )
}
EOF

echo "✅ Production hardening + product polish complete"
