## Unified nimclaw platform tool — replaces nc_assign, nc_claim, nc_submit, nc_send_mail.
## Single tool with `action` parameter dispatching to the appropriate operation.

import std/[os, json, asyncdispatch, tables, strutils, times]
import types
import ../logger

type
  NimclawTool* = ref object of ContextualTool
    workspaceDir*: string

proc newNimclawTool*(workspaceDir: string): NimclawTool =
  result = NimclawTool(workspaceDir: workspaceDir)

method name*(t: NimclawTool): string = "nimclaw"

method description*(t: NimclawTool): string =
  "NimClaw platform operations — task board and inter-agent mail.\n\n" &
  "Actions:\n" &
  "  assign     — Add a task to the To Do list (requires task)\n" &
  "  claim      — Claim a task from To Do → In Progress (requires task_query)\n" &
  "  submit     — Complete a task In Progress → Completed (requires task_query, optional briefing)\n" &
  "  send_mail  — Send mail to another agent (requires recipient, subject, body)\n\n" &
  "Optional: team (default 'default_squad'), lab (overrides team)."

method parameters*(t: NimclawTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["assign", "claim", "submit", "send_mail"],
        "description": "Task operation to perform"
      },
      "task": {
        "type": "string",
        "description": "Task description (for assign)"
      },
      "task_query": {
        "type": "string",
        "description": "Substring to match task (for claim/submit)"
      },
      "team": {
        "type": "string",
        "description": "Team name (default: default_squad)"
      },
      "lab": {
        "type": "string",
        "description": "Lab name (overrides team)"
      },
      "briefing": {
        "type": "string",
        "description": "Summary of accomplishments (for submit)"
      },
      "recipient": {
        "type": "string",
        "description": "Agent name for send_mail"
      },
      "subject": {
        "type": "string",
        "description": "Mail subject (for send_mail)"
      },
      "body": {
        "type": "string",
        "description": "Mail body (for send_mail)"
      }
    },
    "required": %["action"]
  }.toTable

proc getTasksPath(t: NimclawTool, team, lab: string): string =
  if lab != "":
    return t.workspaceDir / "collaboration" / "labs" / lab / "TASKS.md"
  let teamName = if team == "": "default_squad" else: team
  return t.workspaceDir / "collaboration" / "teams" / teamName / "TASKS.md"

method execute*(t: NimclawTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let action = if args.hasKey("action"): args["action"].getStr() else: ""
  let team = if args.hasKey("team"): args["team"].getStr() else: "default_squad"
  let lab = if args.hasKey("lab"): args["lab"].getStr() else: ""

  case action
  of "assign":
    let task = if args.hasKey("task"): args["task"].getStr() else: ""
    if task == "": return "Error: 'task' is required for assign"
    let path = t.getTasksPath(team, lab)
    if not fileExists(path): return "Error: Task board not found at " & path
    try:
      var lines = readFile(path).splitLines()
      var inserted = false
      var newLines: seq[string] = @[]
      for line in lines:
        newLines.add(line)
        if line.contains("## 🔴 To Do"):
          newLines.add("- [ ] " & task)
          inserted = true
      if not inserted:
        newLines.add("\n## 🔴 To Do")
        newLines.add("- [ ] " & task)
      writeFile(path, newLines.join("\n"))
      return "Task added to " & (if lab != "": lab else: team) & " board."
    except Exception as e:
      return "Error: " & e.msg

  of "claim":
    let query = if args.hasKey("task_query"): args["task_query"].getStr().toLowerAscii() else: ""
    if query == "": return "Error: 'task_query' is required for claim"
    let path = t.getTasksPath(team, lab)
    if not fileExists(path): return "Error: Task board not found."
    try:
      var lines = readFile(path).splitLines()
      var taskLineIdx = -1
      var inTodo = false
      for i, line in lines:
        if line.contains("## 🔴 To Do"): inTodo = true
        elif line.startsWith("##"): inTodo = false
        if inTodo and line.toLowerAscii().contains(query) and line.contains("[ ]"):
          taskLineIdx = i
          break
      if taskLineIdx == -1:
        return "Error: Task not found in 'To Do' section or already claimed."
      let taskText = lines[taskLineIdx].replace("- [ ]", "").strip()
      lines.delete(taskLineIdx)
      var inProgressIdx = -1
      for i, line in lines:
        if line.contains("## 🟡 In Progress"):
          inProgressIdx = i
          break
      let claimedLine = "- [ ] " & taskText & " @" & t.agentName
      if inProgressIdx != -1:
        lines.insert(claimedLine, inProgressIdx + 1)
      else:
        lines.add("\n## 🟡 In Progress")
        lines.add(claimedLine)
      writeFile(path, lines.join("\n"))
      return "Task claimed: '" & taskText & "'."
    except Exception as e:
      return "Error: " & e.msg

  of "submit":
    let query = if args.hasKey("task_query"): args["task_query"].getStr().toLowerAscii() else: ""
    if query == "": return "Error: 'task_query' is required for submit"
    let briefing = if args.hasKey("briefing"): args["briefing"].getStr() else: ""
    let path = t.getTasksPath(team, lab)
    if not fileExists(path): return "Error: Task board not found."
    try:
      var lines = readFile(path).splitLines()
      var taskLineIdx = -1
      var inProgress = false
      for i, line in lines:
        if line.contains("## 🟡 In Progress"): inProgress = true
        elif line.startsWith("##") and not line.contains("In Progress"): inProgress = false
        if inProgress and line.toLowerAscii().contains(query):
          taskLineIdx = i
          break
      if taskLineIdx == -1:
        return "Error: Task not found in 'In Progress' list."
      let taskText = lines[taskLineIdx].replace("- [ ]", "").replace("@" & t.agentName, "").strip()
      lines.delete(taskLineIdx)
      var completedIdx = -1
      for i, line in lines:
        if line.contains("## 🟢 Completed"):
          completedIdx = i
          break
      let completedLine = "- [x] " & taskText
      if completedIdx != -1:
        lines.insert(completedLine, completedIdx + 1)
      else:
        lines.add("\n## 🟢 Completed")
        lines.add(completedLine)
      writeFile(path, lines.join("\n"))
      if briefing != "":
        let briefingDir = if lab != "": t.workspaceDir / "collaboration" / "labs" / lab / "briefings"
                          else: t.workspaceDir / "collaboration" / "teams" / team / "briefings"
        if dirExists(briefingDir):
          let bPath = briefingDir / "briefing_" & now().format("yyyyMMdd'_'HHmmss") & "_" & t.agentName.toLowerAscii() & ".md"
          writeFile(bPath, "# Briefing: " & taskText & "\n\nSubmitted by: " & t.agentName & "\n\n" & briefing)
          return "Task completed. Briefing saved."
      return "Task marked as completed."
    except Exception as e:
      return "Error: " & e.msg

  of "send_mail":
    let recipientRaw = if args.hasKey("recipient"): args["recipient"].getStr()
                       elif args.hasKey("to"): args["to"].getStr()
                       else: ""
    if recipientRaw == "": return "Error: 'recipient' is required for send_mail"
    if not args.hasKey("subject"): return "Error: 'subject' is required for send_mail"
    if not args.hasKey("body"): return "Error: 'body' is required for send_mail"
    let recipient = recipientRaw.toLowerAscii().replace("nc:", "")
    let subject = args["subject"].getStr()
    let body = args["body"].getStr()
    let mailDir = t.workspaceDir / "offices" / recipient / "mail"
    if not dirExists(mailDir):
      return "Error: Recipient '" & recipient & "' mailbox not found at " & mailDir
    let timestamp = now().format("yyyyMMdd'_'HHmmss")
    let mailFile = mailDir / "mail_" & timestamp & "_" & t.agentName.toLowerAscii() & ".json"
    let mailData = %*{
      "sender": t.agentName,
      "recipient": recipient,
      "subject": subject,
      "body": body,
      "timestamp": $now()
    }
    try:
      writeFile(mailFile, mailData.pretty())
      infoCF("tool", "Mail sent", {"from": t.agentName, "to": recipient, "file": mailFile}.toTable)
      return "Mail sent to " & recipient
    except Exception as e:
      return "Error: " & e.msg

  else:
    return "Error: Unknown action '" & action & "'. Use: assign, claim, submit, send_mail"
