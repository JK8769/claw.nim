## Unified MCP management tool — replaces forge_mcp_tool, persist_mcp_tool, purge_mcp_tool, persist_skill.
## Single tool with `action` parameter dispatching to the appropriate operation.

import std/[json, tables, asyncdispatch, strutils]
import types, registry
import forge, persist

type
  UnifiedMcpTool* = ref object of ContextualTool
    forgeTool: ForgeTool
    purgeTool: PurgeMcpTool
    persistTool: PersistTool
    persistSkillTool: PersistSkillTool

proc newUnifiedMcpTool*(reg: ToolRegistry, officeDir: string): UnifiedMcpTool =
  UnifiedMcpTool(
    forgeTool: newForgeTool(reg, officeDir),
    purgeTool: newPurgeMcpTool(reg, officeDir),
    persistTool: newPersistTool(reg),
    persistSkillTool: newPersistSkillTool(reg)
  )

method name*(t: UnifiedMcpTool): string = "mcp"

method description*(t: UnifiedMcpTool): string =
  "MCP tool server management — forge, persist, and purge custom tools.\n\n" &
  "Actions:\n" &
  "  forge         — Create & compile a new MCP tool from Nim code (requires name + code)\n" &
  "  persist       — Promote a forged tool to persistent library (requires name, optional version)\n" &
  "  purge         — Unregister & remove an MCP server (requires name, optional delete_source)\n" &
  "  persist_skill — Save a skill to persistent directory (requires skill_name + source_path)\n\n" &
  "Read the forge_nim_expert skill before forging."

method parameters*(t: UnifiedMcpTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["forge", "persist", "purge", "persist_skill"],
        "description": "MCP operation to perform"
      },
      "name": {
        "type": "string",
        "description": "Tool/server name (for forge/persist/purge)"
      },
      "code": {
        "type": "string",
        "description": "Complete Nim MCP server code (for forge)"
      },
      "description": {
        "type": "string",
        "description": "Tool description (for forge)"
      },
      "logic_only": {
        "type": "boolean",
        "description": "Wrap proc defs in MCP boilerplate (for forge)"
      },
      "version": {
        "type": "string",
        "description": "Version number (for persist, default '1.0.0')"
      },
      "comment": {
        "type": "string",
        "description": "Change description (for persist)"
      },
      "delete_source": {
        "type": "boolean",
        "description": "Delete source code too (for purge, default false)"
      },
      "skill_name": {
        "type": "string",
        "description": "Skill folder name (for persist_skill)"
      },
      "source_path": {
        "type": "string",
        "description": "Path to SKILL.md or skill folder (for persist_skill)"
      }
    },
    "required": %["action"]
  }.toTable

method execute*(t: UnifiedMcpTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let action = if args.hasKey("action"): args["action"].getStr() else: ""

  # Forward context to sub-tools
  t.forgeTool.sessionKey = t.sessionKey
  t.forgeTool.agentName = t.agentName
  t.purgeTool.sessionKey = t.sessionKey
  t.purgeTool.agentName = t.agentName
  t.persistTool.sessionKey = t.sessionKey
  t.persistTool.agentName = t.agentName
  t.persistSkillTool.sessionKey = t.sessionKey
  t.persistSkillTool.agentName = t.agentName

  case action
  of "forge":
    return await t.forgeTool.execute(args)
  of "persist":
    return await t.persistTool.execute(args)
  of "purge":
    return await t.purgeTool.execute(args)
  of "persist_skill":
    return await t.persistSkillTool.execute(args)
  else:
    return "Error: Unknown action '" & action & "'. Use: forge, persist, purge, persist_skill"
