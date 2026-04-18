## MCP Stdio Transport implementation using taskpools for concurrent request processing
##
## This module provides the stdio transport implementation for MCP servers.
## It handles JSON-RPC communication over stdin/stdout with concurrent request processing.

import json, locks, options
import lib/malebolgia
import types, protocol, server, composed_server, logging

type 
  StdioTransport* = ref object
    ## Stdio transport implementation for MCP servers
    master: Master
    stdoutLock: Lock
    mcpTransport: McpTransport  # Persistent transport object

proc newStdioTransport*(numThreads: int = 0): StdioTransport =
  ## Args:
  ##   numThreads: Number of worker threads (0 = auto-detect)
  new(result)
  initMaster(result.master)
  initLock(result.stdoutLock)
  result.mcpTransport = McpTransport(kind: tkStdio, capabilities: {})

proc safeEcho(transport: StdioTransport, msg: string) =
  ## Thread-safe output handling
  withLock transport.stdoutLock:
    echo msg
    stdout.flushFile()

# Request processing with Malebolgia
proc handleRequestTask[T: ComposedServer | McpServer](serverPtr: ptr T, transportPtr: ptr StdioTransport, line: string) {.gcsafe.} =
  let server = serverPtr[]
  let transport = transportPtr[]
  var requestId: JsonRpcId = JsonRpcId(kind: jridString, str: "")
  try:
    let request = parseJsonRpcMessage(line)
    if request.id.isSome():
      requestId = request.id.get
    
    if not request.id.isSome():
      # Handle notification (no response needed usually)
      server.handleNotification(transport.mcpTransport, request)
    else:
      # Use context-aware handler
      let response = server.handleRequest(transport.mcpTransport, request)
      transport.safeEcho($response)
  except Exception as e:
    let errorResponse = createJsonRpcError(requestId, ParseError, "Request error: " & e.msg)
    transport.safeEcho($(%errorResponse))

# Main stdio transport serving procedure
proc serve*[T: ComposedServer | McpServer](transport: StdioTransport, server: T) =
  ## Serve the MCP server with stdio transport
  
  # Configure logging to use stderr to avoid interference with MCP protocol on stdout
  server.logger.redirectToStderr()
  server.logger.info("Stdio transport started (using Malebolgia)")

  # Capture local addresses for pointer-based spawning
  var serverAddr = addr server
  var transportAddr = addr transport

  # Use awaitAll to manage the task lifecycle
  transport.master.awaitAll:
    while true:
      try:
        let line = stdin.readLine()
        if line.len == 0:
          continue
        
        # Spawn request handling in a worker thread using pointers to avoid isolation issues
        discard transport.master.spawn handleRequestTask[T](serverAddr, transportAddr, line)
          
      except EOFError:
        break
      except Exception as e:
        server.logger.error("Stdio transport loop error: " & e.msg)
        break

proc sendNotificationToSession*(transport: StdioTransport, sessionId: string, notificationType: string, data: JsonNode) {.gcsafe.} =
  ## Send MCP notification to session (for Stdio transport, there's only one session)
  ## The sessionId parameter is ignored as Stdio has only one client
  let notification = %*{
    "jsonrpc": "2.0",
    "method": "notifications/message",
    "params": %*{
      "type": notificationType,
      "data": data
    }
  }
  transport.safeEcho($notification)

