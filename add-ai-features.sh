#!/bin/bash
set -e

echo "🚀 Extending AI Engine with Claude, OpenAI, RAG, Tools, Diff..."

cd ai-engine

# -------------------------
# OpenAI Model Adapter
# -------------------------
cat > packages/models/src/openai.ts <<'EOF'
import OpenAI from "openai"
import { LLM } from "./base"

const client = new OpenAI({
  apiKey: process.env.OPENAI_API_KEY!
})

export class OpenAIModel implements LLM {
  async *stream(prompt) {
    const stream = await client.chat.completions.create({
      model: "gpt-4o-mini",
      messages: [
        { role: "system", content: prompt.system },
        { role: "user", content: prompt.user }
      ],
      stream: true
    })

    for await (const part of stream) {
      const delta = part.choices?.[0]?.delta?.content
      if (delta) yield delta
    }
  }
}
EOF

# -------------------------
# Update Router (Claude → OpenAI fallback)
# -------------------------
cat > packages/router/src/router.ts <<'EOF'
import { ClaudeModel } from "../../models/src/claude"
import { OpenAIModel } from "../../models/src/openai"

export function chooseModel(task: string) {
  if (task.length > 400 || task.includes("design")) {
    return new ClaudeModel()
  }
  return new OpenAIModel()
}
EOF

# -------------------------
# Qdrant RAG Setup
# -------------------------
cat > packages/context/src/rag.ts <<'EOF'
import OpenAI from "openai"
import { QdrantClient } from "@qdrant/js-client-rest"

const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY })
const qdrant = new QdrantClient({ url: process.env.QDRANT_URL! })

export async function embed(text: string) {
  const res = await openai.embeddings.create({
    model: "text-embedding-3-small",
    input: text
  })
  return res.data[0].embedding
}

export async function storeEmbedding(id: string, text: string) {
  const vector = await embed(text)
  await qdrant.upsert("engine", {
    points: [{ id, vector, payload: { text } }]
  })
}

export async function searchEmbedding(query: string) {
  const vector = await embed(query)
  const res = await qdrant.search("engine", {
    vector,
    limit: 5
  })
  return res.map(r => r.payload?.text).join("\n")
}
EOF

# -------------------------
# Inject RAG into Engine
# -------------------------
cat > packages/engine/src/engine.ts <<'EOF'
import { agentLoop } from "../../agent/src/agent"
import { searchEmbedding } from "../../context/src/rag"

export async function* runEngine(input) {
  const ragContext = await searchEmbedding(input.userMessage)

  yield* agentLoop({
    ...input,
    ragContext
  })
}
EOF

# -------------------------
# Agent uses RAG context
# -------------------------
cat > packages/agent/src/agent.ts <<'EOF'
import { chooseModel } from "../../router/src/router"

export async function* agentLoop(input) {
  const model = chooseModel(input.userMessage)

  for await (const token of model.stream({
    system: "You are an AI Engine. Relevant context:\n" + (input.ragContext || ""),
    user: input.userMessage
  })) {
    yield { type: "token", content: token }
  }

  yield { type: "done" }
}
EOF

# -------------------------
# Diff Tool
# -------------------------
cat > packages/tools/src/diff.ts <<'EOF'
import { diffLines } from "diff"

export function generateDiff(oldText: string, newText: string) {
  return diffLines(oldText, newText)
}
EOF

# -------------------------
# Tool Registry
# -------------------------
cat > packages/tools/src/index.ts <<'EOF'
import fs from "fs"
import path from "path"
import { generateDiff } from "./diff"

const ROOT = process.cwd()

export const tools = {
  read_file: ({ file }) => {
    const full = path.join(ROOT, file)
    return fs.readFileSync(full, "utf8")
  },

  propose_edit: ({ file, newContent }) => {
    const full = path.join(ROOT, file)
    const old = fs.readFileSync(full, "utf8")
    return generateDiff(old, newContent)
  }
}
EOF

echo "✅ Claude + OpenAI + RAG + Tools + Diff added successfully"
