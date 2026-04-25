const SOCKET_PATH = "/tmp/vibe-hud.sock"

import fs from "fs"
import net from "net"

function sendEvent(state, waitForResponse = false) {
  return new Promise((resolve) => {
    const client = net.createConnection(SOCKET_PATH)
    let settled = false
    let buffer = ""

    const finish = (value) => {
      if (settled) return
      settled = true
      resolve(value)
    }

    client.on("connect", () => {
      client.write(JSON.stringify(state))
      if (!waitForResponse) {
        client.end()
        finish(null)
      }
    })

    client.on("data", (chunk) => {
      buffer += chunk.toString("utf8")
    })

    client.on("end", () => {
      if (!waitForResponse) {
        finish(null)
        return
      }

      try {
        finish(buffer ? JSON.parse(buffer) : null)
      } catch {
        finish(null)
      }
    })

    client.on("error", () => {
      finish(null)
    })
  })
}

function roleToEvent(role) {
  if (role === "user") return "UserPromptSubmit"
  if (role === "assistant") return "Stop"
  return "Notification"
}

function nowStatus(role) {
  if (role === "assistant") return "waiting_for_input"
  if (role === "user") return "processing"
  return "notification"
}

function normalizeToolName(tool) {
  if (!tool) return "Tool"
  if (tool === "bash") return "Bash"
  if (tool === "read") return "Read"
  if (tool === "write") return "Write"
  if (tool === "edit") return "Edit"
  if (tool === "glob") return "Glob"
  if (tool === "grep") return "Grep"
  if (tool === "webfetch") return "WebFetch"
  if (tool === "websearch") return "WebSearch"
  if (tool === "task") return "Agent"
  return tool
}

function normalizeToolInput(input) {
  if (!input || typeof input !== "object") return {}
  const result = {}
  for (const [key, value] of Object.entries(input)) {
    if (value === undefined || value === null) continue
    result[key] = value
  }
  return result
}

function buildBaseState(sessionID, cwd) {
  return {
    session_id: sessionID,
    cwd: cwd || process.cwd(),
    source: "opencode",
    transcript_path: opencodeSessionFile(sessionID),
  }
}

function opencodeDataDir() {
  return process.env.HOME ? `${process.env.HOME}/.local/share/opencode/storage` : ""
}

function opencodeSessionFile(sessionID) {
  const storageDir = opencodeDataDir()
  if (!storageDir || !sessionID) return null

  try {
    const sessionRoot = `${storageDir}/session`
    for (const project of fs.readdirSync(sessionRoot)) {
      const candidate = `${sessionRoot}/${project}/${sessionID}.json`
      if (fs.existsSync(candidate)) return candidate
    }
  } catch {}

  return null
}

export default async function VibeHUDPlugin() {
  return {
    async event(input) {
      const event = input?.event
      if (!event) return

      const type = event.type
      const props = event.properties || {}

      if (type === "session.created" || type === "session.updated") {
        await sendEvent({
          ...buildBaseState(props.info?.id || props.sessionID, props.info?.directory),
          event: type === "session.created" ? "SessionStart" : "Notification",
          status: props.info?.time?.archived ? "ended" : "waiting_for_input",
          message: props.info?.title,
        })
        return
      }

      if (type === "session.deleted") {
        await sendEvent({
          ...buildBaseState(props.info?.id || props.sessionID, props.info?.directory),
          event: "SessionEnd",
          status: "ended",
        })
        return
      }

      if (type === "session.idle") {
        await sendEvent({
          ...buildBaseState(props.sessionID, process.cwd()),
          event: "Stop",
          status: "waiting_for_input",
        })
        return
      }

      if (type === "message.part.updated") {
        const part = props.part || {}
        if (part.type === "tool") {
          const toolName = normalizeToolName(part.tool)
          const toolInput = normalizeToolInput(part.state?.input)
          const callID = part.callID || part.id

          if (part.state?.status === "running") {
            await sendEvent({
              ...buildBaseState(part.sessionID, process.cwd()),
              event: "PreToolUse",
              status: "running_tool",
              tool: toolName,
              tool_input: toolInput,
              tool_use_id: callID,
            })
            return
          }

          if (part.state?.status === "completed" || part.state?.status === "error") {
            await sendEvent({
              ...buildBaseState(part.sessionID, process.cwd()),
              event: "PostToolUse",
              status: "processing",
              tool: toolName,
              tool_input: toolInput,
              tool_use_id: callID,
            })
            return
          }
        }
      }
    },

    async "chat.message"(input, output) {
      const text = output?.parts?.find((part) => part?.type === "text")?.text
      await sendEvent({
        ...buildBaseState(input.sessionID, process.cwd()),
        event: roleToEvent(output?.message?.role),
        status: nowStatus(output?.message?.role),
        message: text,
      })
    },

    async "tool.execute.before"(input, output) {
      await sendEvent({
        ...buildBaseState(input.sessionID, process.cwd()),
        event: "PreToolUse",
        status: "running_tool",
        tool: normalizeToolName(input.tool),
        tool_input: normalizeToolInput(output?.args),
        tool_use_id: input.callID,
      })
    },

    async "tool.execute.after"(input, output) {
      await sendEvent({
        ...buildBaseState(input.sessionID, process.cwd()),
        event: "PostToolUse",
        status: "processing",
        tool: normalizeToolName(input.tool),
        tool_input: {},
        tool_use_id: input.callID,
        message: output?.output,
      })
    },

    async "permission.ask"(input, output) {
      const toolName = normalizeToolName(input.metadata?.tool || input.metadata?.name || input.permission)
      const response = await sendEvent({
        ...buildBaseState(input.sessionID, process.cwd()),
        event: "PermissionRequest",
        status: "waiting_for_approval",
        tool: toolName,
        tool_input: {
          permission: input.permission,
          patterns: Array.isArray(input.patterns) ? input.patterns.join(", ") : "",
          message: input.message || "",
          ...(input.metadata || {}),
        },
        tool_use_id: input.callID || input.id,
      }, true)

      const decision = response?.decision
      if (decision === "allow") {
        output.status = "allow"
      } else if (decision === "deny") {
        output.status = "deny"
      }
    },
  }
}
