## consolidate_knowledge — agent's tool for promoting an insight from
## per-project context into her cross-project semantic memory at
## `<office>/knowledge/<topic>.md`.
##
## The knowledge/ directory is the agent's personal wiki — timeless
## facts, recall-on-demand. Distinct from:
##   - memory/MEMORY.md     (always-on behavioural reflexes)
##   - memory/<nc:id>.jsonl (episodic per-partner experiences)
##   - workstation/active/<project>/  (project-bound notes that
##     stay with the project)
##
## When to use:
##   - You discover a fact while working on project A that applies
##     beyond it (a Sungrow API quirk, a model methodology, a
##     vendor-specific gotcha). Promote to knowledge/.
##   - When archiving a project, extract its durable insights here
##     before the project goes cold in archive/.
##
## When NOT to use:
##   - Project-specific data → keep in `workstation/active/<project>/`
##   - Behavioral rules ("always confirm scope") → MEMORY.md
##   - Episodic events ("nc:5 cancelled my turn") → memory/<nc:id>.jsonl
##
## File format inside knowledge/<topic>.md:
##
##   # <topic>
##
##   ## YYYY-MM-DD HH:MM (added by <agent>)
##
##   <insight>
##
##   **Source**: <source if provided>
##
##   ## (next entry stacks below — append-only, oldest at top)

import std/[asyncdispatch, json, tables, strutils, times, os, osproc]
import ../types
import ../spec
import ../../logger

const ToolSpec* = spec(
  name = "consolidate_knowledge",
  description = "promote a cross-project insight into your knowledge wiki at knowledge/<topic>.md",
  tags = @["agent", "core"],
  domain = "agent",
  default = true,
  heartbeatSafe = true,
  category = "self-management",
)

type
  ConsolidateKnowledgeTool* = ref object of ContextualTool
    workspace*: string         ## agent's office dir
    agentLabel*: string        ## for attribution in entries (set at construction;
                               ## ContextualTool.agentName is set per-call by the
                               ## context-binding hook and may be empty when the
                               ## call comes from outside a normal turn)

proc newConsolidateKnowledgeTool*(workspace, agentName: string): ConsolidateKnowledgeTool =
  ConsolidateKnowledgeTool(workspace: workspace, agentLabel: agentName)

method name*(t: ConsolidateKnowledgeTool): string = "consolidate_knowledge"

method description*(t: ConsolidateKnowledgeTool): string =
  "Promote an insight from project context into your cross-project " &
  "knowledge wiki at `knowledge/<topic>.md`. Use when you discover " &
  "a fact that applies beyond the current project (API quirks, " &
  "domain facts, technique notes, vendor-specific gotchas). Lands " &
  "as a timestamped entry in the topic file (creates the file on " &
  "first call, appends thereafter). Recall-on-demand later via " &
  "`read_file knowledge/<topic>.md` or `grep -r <term> knowledge/`. " &
  "Distinct from MEMORY.md (behavioural reflexes — always-on) and " &
  "memory/<nc:id>.jsonl (episodic per-partner events). Don't use " &
  "for project-specific notes — those stay in the project's repo."

method parameters*(t: ConsolidateKnowledgeTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "topic": {
        "type": "string",
        "minLength": 2,
        "pattern": "^[a-z0-9-]+$",
        "description": "Filename slug, kebab-case (lowercase letters/digits/hyphens). Becomes <topic>.md. Examples: 'sungrow-api-quirks', 'gbdt-clearing-features', 'plant-failure-modes-sg110cx'. Aim for nouns that describe the topic — future-you will grep for them."
      },
      "insight": {
        "type": "string",
        "minLength": 10,
        "description": "The fact / observation / lesson, written so future-you can act on it without the original context. 1-3 sentences usually. Don't include narrative ('I noticed...') — write the lesson directly."
      },
      "source": {
        "type": "string",
        "description": "Optional: where this came from (project name, conversation snippet, external reference). Helps future-you trust or revisit the claim."
      }
    },
    "required": %*["topic", "insight"]
  }.toTable

proc isKebabSafe(s: string): bool =
  if s.len < 2: return false
  for ch in s:
    if not (ch in {'a'..'z', '0'..'9', '-'}): return false
  if s[0] == '-' or s[^1] == '-': return false
  return true

proc ensureKnowledgeRepo(workspace: string): bool =
  ## Create knowledge/ + git init if missing. Idempotent — safe to
  ## call on every consolidate. Returns true on success / already-set,
  ## false if the dir / git ops failed.
  let knowledgeDir = workspace / "knowledge"
  if not dirExists(knowledgeDir):
    try: createDir(knowledgeDir)
    except CatchableError as e:
      warnCF("consolidate_knowledge", "Failed to create knowledge/",
             {"path": knowledgeDir, "error": e.msg}.toTable)
      return false
  if not dirExists(knowledgeDir / ".git"):
    # Quick git init, no remote, ignore typical noise
    let initCmd = "cd '" & knowledgeDir & "' && " &
                  "git init -q && " &
                  "echo -e '.DS_Store\\n*.swp\\n' > .gitignore && " &
                  "git add .gitignore && " &
                  "git commit -q -m 'Initial knowledge wiki' --allow-empty"
    let (output, exitCode) = execCmdEx(initCmd)
    if exitCode != 0:
      warnCF("consolidate_knowledge", "git init failed in knowledge/",
             {"path": knowledgeDir, "output": output}.toTable)
      # Don't fail the whole tool — file write can still proceed
  return true

method execute*(t: ConsolidateKnowledgeTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("topic"):
    return "Error: Missing 'topic' parameter"
  if not args.hasKey("insight"):
    return "Error: Missing 'insight' parameter"
  let topic = args["topic"].getStr().strip()
  let insight = args["insight"].getStr().strip()
  if topic.len == 0: return "Error: 'topic' must not be empty"
  if insight.len == 0: return "Error: 'insight' must not be empty"
  if not isKebabSafe(topic):
    return "Error: 'topic' must be kebab-case (lowercase letters, digits, " &
           "hyphens; no leading/trailing/double hyphens). Got: '" & topic & "'"
  if t.workspace.len == 0:
    return "Error: tool not bound to an office workspace"
  let source = if args.hasKey("source"): args["source"].getStr().strip() else: ""

  discard ensureKnowledgeRepo(t.workspace)
  let knowledgePath = t.workspace / "knowledge" / topic & ".md"
  let isNew = not fileExists(knowledgePath)

  let now = now().format("yyyy-MM-dd HH:mm")
  let agentLabel = if t.agentLabel.len > 0: t.agentLabel else: "agent"

  var entry = ""
  if isNew:
    entry.add("# " & topic & "\n\n")
  entry.add("## " & now & " (added by " & agentLabel & ")\n\n")
  entry.add(insight & "\n")
  if source.len > 0:
    entry.add("\n**Source**: " & source & "\n")
  entry.add("\n")

  try:
    let f = open(knowledgePath, fmAppend)
    f.write(entry)
    f.close()
  except CatchableError as e:
    return "Error: failed to write knowledge entry: " & e.msg

  let action = if isNew: "Created new knowledge entry" else: "Appended to existing knowledge"
  return action & " at `knowledge/" & topic & ".md`. Recall later via " &
         "`read_file knowledge/" & topic & ".md` or `grep -r <term> knowledge/`."
