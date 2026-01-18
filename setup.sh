#!/bin/bash
set -e

echo "🚀 Bootstrapping AI Engine..."

mkdir -p ai-engine
cd ai-engine

mkdir -p apps/{web,api}
mkdir -p apps/api/src/{routes}
mkdir -p apps/web/app/api/chat
mkdir -p packages/{engine,agent,context,tools,models,router}/src
mkdir -p prisma

cat > .env.example <<EOF
ANTHROPIC_API_KEY=
OPENAI_API_KEY=
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/aiengine
QDRANT_URL=http://localhost:6333
EOF

cat > packages/engine/src/types.ts <<'EOF'
export type EngineInput = {
  userMessage: string
  sessionId: string
  files?: { path: string; content: string }[]
}

export type EngineOutput =
  | { type: "token"; content: string }
  | { type: "tool"; content: string }
  | { type: "done" }
EOF

cat > packages/agent/src/agent.ts <<'EOF'
import { chooseModel } from "../../router/src/router"

export async function* agentLoop(input) {
  const model = chooseModel(input.userMessage)

  for await (const token of model.stream({
    system: "You are an AI Engine with tools and memory.",
    user: input.userMessage
  })) {
    yield { type: "token", content: token }
  }

  yield { type: "done" }
}
EOF

cat > packages/engine/src/engine.ts <<'EOF'
import { agentLoop } from "../../agent/src/agent"

export async function* runEngine(input) {
  yield* agentLoop(input)
}
EOF

cat > packages/models/src/base.ts <<'EOF'
export interface LLM {
  stream(prompt: {
    system: string
    user: string
  }): AsyncGenerator<string>
}
EOF

cat > packages/models/src/claude.ts <<'EOF'
import Anthropic from "@anthropic-ai/sdk"
import { LLM } from "./base"

const client = new Anthropic({
  apiKey: process.env.ANTHROPIC_API_KEY!
})

export class ClaudeModel implements LLM {
  async *stream(prompt) {
    const stream = await client.messages.create({
      model: "claude-3-5-sonnet-20241022",
      max_tokens: 2048,
      messages: [
        { role: "system", content: prompt.system },
        { role: "user", content: prompt.user }
      ],
      stream: true
    })

    for await (const event of stream) {
      if (event.type === "content_block_delta") {
        yield event.delta.text
      }
    }
  }
}
EOF

cat > packages/models/src/fast.ts <<'EOF'
export class FastModel {
  async *stream() {
    yield "Fast model placeholder\n"
  }
}
EOF

cat > packages/router/src/router.ts <<'EOF'
import { ClaudeModel } from "../../models/src/claude"
import { FastModel } from "../../models/src/fast"

export function chooseModel(task: string) {
  if (task.length > 300 || task.includes("design")) {
    return new ClaudeModel()
  }
  return new FastModel()
}
EOF

cat > apps/api/src/server.ts <<'EOF'
import Fastify from "fastify"
import { chatRoute } from "./routes/chat"

const app = Fastify({ logger: true })
app.register(chatRoute, { prefix: "/chat" })

app.listen({ port: 3001 }, () => {
  console.log("API running on http://localhost:3001")
})
EOF

cat > apps/api/src/routes/chat.ts <<'EOF'
import { runEngine } from "../../../packages/engine/src/engine"

export async function chatRoute(app) {
  app.post("/", async (req, reply) => {
    const { message } = req.body

    reply.raw.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache"
    })

    for await (const chunk of runEngine({
      userMessage: message,
      sessionId: "local"
    })) {
      if (chunk.type === "token") {
        reply.raw.write(chunk.content)
      }
    }

    reply.raw.end()
  })
}
EOF

cat > apps/web/app/page.tsx <<'EOF'
"use client"
import { useState } from "react"

export default function Page() {
  const [input, setInput] = useState("")
  const [output, setOutput] = useState("")

  async function send() {
    const res = await fetch("http://localhost:3001/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message: input })
    })

    const reader = res.body.getReader()
    const decoder = new TextDecoder()

    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      setOutput(o => o + decoder.decode(value))
    }
  }

  return (
    <div>
      <textarea onChange={e => setInput(e.target.value)} />
      <button onClick={send}>Send</button>
      <pre>{output}</pre>
    </div>
  )
}
EOF

echo "✅ AI Engine bootstrap completed"
