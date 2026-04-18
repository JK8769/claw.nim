import std/[os, json, asyncdispatch, tables, strutils, times]
import types
import ../logger

type
  SendMailTool* = ref object of ContextualTool
    workspaceDir*: string

proc newSendMailTool*(workspaceDir: string): SendMailTool =
  result = SendMailTool(workspaceDir: workspaceDir)

method name*(t: SendMailTool): string = "nc_send_mail"
method description*(t: SendMailTool): string = "Send a professional email/memo to another agent's mailbox."
method parameters*(t: SendMailTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "recipient": {
        "type": "string",
        "description": "The name of the recipient agent (e.g. 'Raven')"
      },
      "subject": {
        "type": "string",
        "description": "The subject of the mail"
      },
      "body": {
        "type": "string",
        "description": "The content of the mail"
      }
    },
    "required": %["subject", "body"]
  }.toTable

method execute*(t: SendMailTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let recipientRaw = if args.hasKey("recipient"): args["recipient"].getStr() 
                     elif args.hasKey("to"): args["to"].getStr()
                     else: ""
  
  if recipientRaw == "":
    return "Error: Missing required parameter 'recipient' or 'to'"
    
  let recipient = recipientRaw.toLowerAscii().replace("nc:", "")
  let subject = args["subject"].getStr()
  let body = args["body"].getStr()
  
  let mailDir = t.workspaceDir / "offices" / recipient / "mail"
  if not dirExists(mailDir):
    return "Error: Recipient '" & recipient & "' does not have a professional mailbox at " & mailDir
  
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
    return "Mail sent successfully to " & recipient
  except Exception as e:
    return "Error: Failed to send mail: " & e.msg

type
  TaskOrchestratorTool* = ref object of ContextualTool
    workspaceDir*: string

proc newTaskOrchestratorTool*(workspaceDir: string): TaskOrchestratorTool =
  result = TaskOrchestratorTool(workspaceDir: workspaceDir)

proc getTasksPath(t: TaskOrchestratorTool, team, lab: string): string =
  if lab != "":
    return t.workspaceDir / "collaboration" / "labs" / lab / "TASKS.md"
  let teamName = if team == "": "default_squad" else: team
  return t.workspaceDir / "collaboration" / "teams" / teamName / "TASKS.md"

method name*(t: TaskOrchestratorTool): string = "nc_assign"
method description*(t: TaskOrchestratorTool): string = "Assign a new task to the team's shared task board."
method parameters*(t: TaskOrchestratorTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "task": {
        "type": "string",
        "description": "Description of the task"
      },
      "team": {
        "type": "string",
        "description": "Optional: Team name (defaults to 'default_squad')"
      },
      "lab": {
        "type": "string",
        "description": "Optional: Lab name (if working in a lab instead of a team)"
      }
    },
    "required": %["task"]
  }.toTable

method execute*(t: TaskOrchestratorTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let task = args["task"].getStr()
  let team = if args.hasKey("team"): args["team"].getStr() else: "default_squad"
  let lab = if args.hasKey("lab"): args["lab"].getStr() else: ""
  
  let path = t.getTasksPath(team, lab)
  if not fileExists(path):
    return "Error: Task board not found at " & path
  
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
    return "Task successfully added to " & (if lab != "": lab else: team) & " board."
  except Exception as e:
    return "Error: Failed to update task board: " & e.msg

type
  ClaimTaskTool* = ref object of ContextualTool
    workspaceDir*: string

proc newClaimTaskTool*(workspaceDir: string): ClaimTaskTool =
  result = ClaimTaskTool(workspaceDir: workspaceDir)

method name*(t: ClaimTaskTool): string = "nc_claim"
method description*(t: ClaimTaskTool): string = "Claim an unassigned task from the shared task board."
method parameters*(t: ClaimTaskTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "task_query": {
        "type": "string",
        "description": "Substring or ID of the task to claim"
      },
      "team": {
        "type": "string",
        "description": "Optional: Team name"
      },
      "lab": {
        "type": "string",
        "description": "Optional: Lab name"
      }
    },
    "required": %["task_query"]
  }.toTable

method execute*(t: ClaimTaskTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let query = args["task_query"].getStr().toLowerAscii()
  let team = if args.hasKey("team"): args["team"].getStr() else: "default_squad"
  let lab = if args.hasKey("lab"): args["lab"].getStr() else: ""
  
  let path = if lab != "": t.workspaceDir / "collaboration" / "labs" / lab / "TASKS.md"
             else: t.workspaceDir / "collaboration" / "teams" / team / "TASKS.md"
             
  if not fileExists(path): return "Error: Task board not found."
  
  try:
    var content = readFile(path)
    var lines = content.splitLines()
    var taskLineIdx = -1
    
    # 1. Find the task in To Do
    var inTodo = false
    for i, line in lines:
      if line.contains("## 🔴 To Do"): inTodo = true
      elif line.startsWith("##"): inTodo = false
      
      if inTodo and line.toLowerAscii().contains(query) and line.contains("[ ]"):
        taskLineIdx = i
        break
    
    if taskLineIdx == -1:
      return "Error: Task not found in 'To Do' section or already claimed."
    
    # 2. Extract and modify
    let taskText = lines[taskLineIdx].replace("- [ ]", "").strip()
    lines.delete(taskLineIdx)
    
    # 3. Add to In Progress
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
    return "Task claimed: '" & taskText & "'. It is now in your 'In Progress' list."
  except Exception as e:
    return "Error: " & e.msg

type
  SubmitTaskTool* = ref object of ContextualTool
    workspaceDir*: string

proc newSubmitTaskTool*(workspaceDir: string): SubmitTaskTool =
  result = SubmitTaskTool(workspaceDir: workspaceDir)

method name*(t: SubmitTaskTool): string = "nc_submit"
method description*(t: SubmitTaskTool): string = "Move a claimed task to 'Completed' and notify the lead."
method parameters*(t: SubmitTaskTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "task_query": {
        "type": "string",
        "description": "Substring of the task you finished"
      },
      "team": {
        "type": "string",
        "description": "Optional: Team name"
      },
      "lab": {
        "type": "string",
        "description": "Optional: Lab name"
      },
      "briefing": {
        "type": "string",
        "description": "Optional: A brief summary of what was accomplished"
      }
    },
    "required": %["task_query"]
  }.toTable

method execute*(t: SubmitTaskTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let query = args["task_query"].getStr().toLowerAscii()
  let team = if args.hasKey("team"): args["team"].getStr() else: "default_squad"
  let lab = if args.hasKey("lab"): args["lab"].getStr() else: ""
  let briefing = if args.hasKey("briefing"): args["briefing"].getStr() else: ""
  
  let path = if lab != "": t.workspaceDir / "collaboration" / "labs" / lab / "TASKS.md"
             else: t.workspaceDir / "collaboration" / "teams" / team / "TASKS.md"
             
  if not fileExists(path): return "Error: Task board not found."
  
  try:
    var lines = readFile(path).splitLines()
    var taskLineIdx = -1
    
    # 1. Find in In Progress
    var inProgress = false
    for i, line in lines:
      if line.contains("## 🟡 In Progress"): inProgress = true
      elif line.startsWith("##") and not line.contains("In Progress"): inProgress = false
      
      if inProgress and line.toLowerAscii().contains(query):
        taskLineIdx = i
        break
        
    if taskLineIdx == -1:
      return "Error: Task not found in your 'In Progress' list."
      
    # 2. Mark as completed
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
    
    # 3. Write briefing if provided
    if briefing != "":
        let briefingDir = if lab != "": t.workspaceDir / "collaboration" / "labs" / lab / "briefings"
                          else: t.workspaceDir / "collaboration" / "teams" / team / "briefings"
        if dirExists(briefingDir):
            let bPath = briefingDir / "briefing_" & now().format("yyyyMMdd'_'HHmmss") & "_" & t.agentName.toLowerAscii() & ".md"
            writeFile(bPath, "# Briefing: " & taskText & "\n\nSubmitted by: " & t.agentName & "\n\n" & briefing)
            return "Task submitted and briefing recorded at " & bPath
            
    return "Task marked as completed."
  except Exception as e:
    return "Error: " & e.msg
