## NimCP - Easy Model Context Protocol (MCP) server implementation for Nim
## 
## This module provides a high-level, macro-based API for creating MCP servers
## that integrate seamlessly with LLM applications.

import ./mcp/[types, protocol, server, mcpmacros, stdio_transport, context, schema, resource_templates, logging, client]
import std/isolation

export types, server, protocol, stdio_transport, context, schema, resource_templates, logging, isolation, client
export mcpmacros.mcpServer, mcpmacros.mcpTool, mcpmacros.mcpResource, mcpmacros.mcpPrompt