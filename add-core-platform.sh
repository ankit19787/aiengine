#!/bin/bash
set -e

echo "🚀 Adding Repo Ingestion, Planner Tool-Calling, and Security Layer..."

cd ai-engine

# -------------------------
# 1️⃣ GitHub Repo Ingestion
# -------------------------
cat > packages/context/src/ingest.ts <<'EOF'
import simpleGit from "simple-git"
import fs from "fs"
import path from "path"
import { storeEmbedding } from "./rag"

function walk(dir: string): string[] {
  return fs.readdirSync(dir).flatMap(file => {
    const full = path.join(dir, file)
    return fs.statSync(full).isDirectory() ? walk(full) : [full]
  })
}

export async function ingestRepo(repoUrl: string, workspace = "default") {
  const target = `/tmp/${workspace}`
  await simpleGit().clone(repoUrl, target)

  const files = walk(target).filter(f => /\.(ts|js|md|json)$/.test(f))

  for (const file of files) {
    const content = fs.readFileSync(file, "utf8")
    await storeEmbedding(file, content)
  }

  return { filesIndexed: files.length }
}
EOF

# -------------------------
# 2️⃣ Planner + Tool Calling
# -------------------------
cat > packages/agent/src/planner.ts <<'EOF'
import { z } from "zod"

export const ToolCallSchema = z.object({
  tool: z.enum(["read_file", "propose_edit"]),
  params: z.record(z.any())
})

export function parseToolCall(text: string) {
  try {
    const json = JSON.parse(text)
    return ToolCallSchema.parse(json)
  } catch {
    return null
  }
}
EOF

cat > packages/agent/src/agent.ts <<'EOF'
import { chooseModel } from "../../router/src/router"
import { parseToolCall } from "./planner"
import { tools } from "../../tools/src"

export async function* agentLoop(input) {
  const model = chooseModel(input.userMessage)

  let buffer = ""

  for await (const token of model.stream({
    system: "You are an AI agent. If a tool is needed, respond ONLY in JSON.",
    user: input.userMessage
  })) {
    buffer += token
    yield { type: "token", content: token }
  }

  const toolCall = parseToolCall(buffer)
  if (toolCall) {
    const result = await tools[toolCall.tool](toolCall.params)
    yield { type: "tool", content: JSON.stringify(result) }
  }

  yield { type: "done" }
}
EOF

# -------------------------
# 3️⃣ Auth + Rate Limiting
# -------------------------
cat > apps/api/src/middleware/security.ts <<'EOF'
const RATE_LIMIT = new Map()

export function authAndRateLimit(req, reply, done) {
  const key = req.headers.authorization
  if (!key) return reply.status(401).send("Unauthorized")

  const now = Date.now()
  const record = RATE_LIMIT.get(key) || []
  const recent = record.filter(t => now - t < 60000)

  if (recent.length > 60) {
    return reply.status(429).send("Rate limit exceeded")
  }

  recent.push(now)
  RATE_LIMIT.set(key, recent)
  done()
}
EOF

# -------------------------
# Apply Middleware
# -------------------------
cat > apps/api/src/server.ts <<'EOF'
import Fastify from "fastify"
import { chatRoute } from "./routes/chat"
import { authAndRateLimit } from "./middleware/security"

const app = Fastify({ logger: true })

app.addHook("preHandler", authAndRateLimit)
app.register(chatRoute, { prefix: "/chat" })

app.listen({ port: 3001 }, () => {
  console.log("API running on http://localhost:3001")
})
EOF

echo "✅ Repo ingestion, planner tool-calling, and security added"
