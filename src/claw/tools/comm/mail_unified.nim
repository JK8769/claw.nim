## mail — single tool for inter-agent mail.
##
## Actions:
##
##   send
##     Drop a JSON envelope into another agent's `<office>/mail/`.
##     Triggers MAILBOX ALERT in the recipient's next prompt build
##     and heartbeat tick. Requires recipient, subject, body.
##
##   archive
##     Move a processed mail out of your own inbox to
##     `<office>/mail/processed/<filename>`. Without this the same
##     MAILBOX ALERT keeps firing every prompt build forever.
##     Path-safe: only the basename of `filename` is honoured.
##     Requires filename.
##
## Wiring: `workspaceDir` resolves recipient offices for `send`;
## `officeDir` resolves the agent's own inbox for `archive`. They
## differ — workspace is the company root, office is per-agent.

import std/[os, json, asyncdispatch, tables, strutils, times]
import ../types
import ../spec
import ../../logger

const ToolSpec* = spec(
  name = "mail",
  description = "Inter-agent mail (send to peers; archive your own processed inbox)",
  tags = @["agent", "core", "messaging"],
  domain = "comm",
  default = true,
  heartbeatSafe = true,
  category = "comm",
)

type
  MailTool* = ref object of ContextualTool
    workspaceDir*: string
    officeDir*: string

proc newMailTool*(workspaceDir, officeDir: string): MailTool =
  MailTool(workspaceDir: workspaceDir, officeDir: officeDir)

method name*(t: MailTool): string = "mail"

method description*(t: MailTool): string =
  "ASYNC inter-agent message (file-persisted). Drop a note in another " &
  "agent's mailbox; they read it on their next heartbeat. Use when you " &
  "want to inform a peer without blocking your own turn. For other " &
  "comm needs:\n" &
  "  • respond to current partner       → use `reply`\n" &
  "  • SYNC task that returns a result  → use `delegate` (waits for reply)\n" &
  "  • bridge guest ↔ internal staff    → use `forward`\n\n" &
  "Actions:\n" &
  "  send    — deliver a mail to another agent's mailbox " &
  "(requires recipient, subject, body)\n" &
  "  archive — move a mail you've processed out of your inbox " &
  "(requires filename, as shown in MAILBOX ALERT)\n\n" &
  "Always call `archive` after acting on a mail, otherwise " &
  "the same alert fires in every future heartbeat tick."

method parameters*(t: MailTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["send", "archive"],
        "description": "Operation to perform"
      },
      "recipient": {
        "type": "string",
        "description": "Recipient agent name (action=send)"
      },
      "subject": {
        "type": "string",
        "description": "Mail subject (action=send)"
      },
      "body": {
        "type": "string",
        "description": "Mail body (action=send)"
      },
      "filename": {
        "type": "string",
        "description": "Bare mail filename to archive (action=archive). Path components stripped — basename only."
      }
    },
    "required": %["action"]
  }.toTable

proc doSend(t: MailTool, args: Table[string, JsonNode]): string =
  let recipientRaw = if args.hasKey("recipient"): args["recipient"].getStr()
                     elif args.hasKey("to"): args["to"].getStr()
                     else: ""
  if recipientRaw.len == 0:
    return "Error: 'recipient' is required for send"
  if not args.hasKey("subject"): return "Error: 'subject' is required for send"
  if not args.hasKey("body"): return "Error: 'body' is required for send"

  let recipient = recipientRaw.toLowerAscii().replace("nc:", "")
  let subject = args["subject"].getStr()
  let body = args["body"].getStr()

  let mailDir = t.workspaceDir / "offices" / recipient / "mail"
  if not dirExists(mailDir):
    return "Error: Recipient '" & recipient &
           "' mailbox not found at " & mailDir

  let timestamp = now().format("yyyyMMdd'_'HHmmss")
  let mailFile = mailDir / "mail_" & timestamp & "_" &
                 t.agentName.toLowerAscii() & ".json"
  let mailData = %*{
    "sender": t.agentName,
    "recipient": recipient,
    "subject": subject,
    "body": body,
    "timestamp": $now()
  }
  try:
    writeFile(mailFile, mailData.pretty())
  except CatchableError as e:
    return "Error: " & e.msg
  if not fileExists(mailFile):
    return "Error: writeFile reported success but file not found at " &
           mailFile & " (recipient may not see this mail — check disk space, permissions)"
  infoCF("tool", "Mail sent",
         {"from": t.agentName, "to": recipient,
          "file": mailFile}.toTable)
  return "Mail sent to " & recipient & " (verified at " & mailFile & ")"

proc doArchive(t: MailTool, args: Table[string, JsonNode]): string =
  if t.officeDir.len == 0:
    return "Error: tool not bound to an office workspace"
  if not args.hasKey("filename"):
    return "Error: 'filename' is required for archive"
  let raw = args["filename"].getStr().strip()
  if raw.len == 0:
    return "Error: 'filename' must not be empty"

  let basename = extractFilename(raw)
  if basename.len == 0 or basename == "." or basename == "..":
    return "Error: invalid filename '" & raw & "'"
  if basename == ".gitkeep":
    return "Error: refusing to archive .gitkeep"

  let mailDir = t.officeDir / "mail"
  let src = mailDir / basename
  if not fileExists(src):
    return "Error: mail file not found at " & src &
           " (already archived, or filename mistyped)"

  let processedDir = mailDir / "processed"
  try:
    createDir(processedDir)
  except CatchableError as e:
    return "Error: failed to create processed/ dir: " & e.msg

  let dst = processedDir / basename
  try:
    moveFile(src, dst)
  except CatchableError as e:
    return "Error: failed to move mail to processed/: " & e.msg

  return "Archived mail to " & dst &
         ". MAILBOX ALERT will no longer fire for this file."

method execute*(t: MailTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: 'action' is required (send | archive)"
  let action = args["action"].getStr()
  case action
  of "send":    return doSend(t, args)
  of "archive": return doArchive(t, args)
  else:
    return "Error: Unknown action '" & action & "'. Use: send | archive"
