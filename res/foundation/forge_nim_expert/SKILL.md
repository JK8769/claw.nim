---
name: forge_nim_expert
description: How to use forge_mcp_tool to create runtime MCP tools in Nim. Read this BEFORE calling forge_mcp_tool.
---

# Forge MCP Tool — Correct Usage

## CRITICAL: Call `forge_mcp_tool`, NOT `write_file` + `exec`

Do NOT manually write .nim files and compile them. Use the `forge_mcp_tool` tool which handles compilation, sandboxing, and registration automatically.

## NEW: "Logic-Only" Mode (Recommended)

To avoid boilerplate, you can provide ONLY the proc definitions and set `logic_only: true`. The tool will automatically wrap your code in the necessary MCP structure and standard imports.

```xml
<tool_call>
  <name>forge_mcp_tool</name>
  <arguments>
    <name>my_logic_tool</name>
    <logic_only>true</logic_only>
    <code>
proc hello(name: string): string =
  ## Simple hello tool
  ## - name: person to greet
  return "Hello, " & name
    </code>
  </arguments>
</tool_call>
```

## Manual Code Template (Expert Mode)

If you need custom imports or advanced server configuration, set `logic_only: false` (default) and use this template:

```nim
import mcp
import std/[json, os, strutils]

let server = mcpServer("tool_name", "1.0.0"):
  mcpTool:
    proc my_tool(path: string): string =
      ## Short description of what this tool does
      ## - path: what this parameter means
      return "result string or JSON"

when isMainModule:
  let transport = newStdioTransport()
  transport.serve(server)
```

## How to Call forge_mcp_tool

Use XML argument blocks (NOT JSON) to avoid escaping issues:

```xml
<tool_call>
  <name>forge_mcp_tool</name>
  <arguments>
    <name>my_analyzer</name>
    <description>Analyzes Nim project structure</description>
    <code>
import mcp
import std/[json, os, strutils]

let server = mcpServer("my_analyzer", "1.0.0"):
  mcpTool:
    proc analyze(project_path: string): string =
      ## Analyze a Nim project directory
      ## - project_path: path to the project root
      var files: seq[string] = @[]
      for f in walkDirRec(project_path):
        if f.endsWith(".nim"):
          files.add(f)
      return $(%*{"nim_files": files, "count": files.len})

when isMainModule:
  let transport = newStdioTransport()
  transport.serve(server)
    </code>
  </arguments>
</tool_call>
```

## Persisting Your Forged Tools

By default, forged tools are ephemeral and lost when the session restarts. To save a useful tool to your permanent library:

```xml
<tool_call>
  <name>persist_mcp_tool</name>
  <arguments>
    <name>my_analyzer</name>
    <version>1.0.0</version>
    <comment>Added recursive analysis support</comment>
  </arguments>
</tool_call>
```

This moves the source and binary to your agent's local `workstation/mcp/` folder and ensures they are persistent across logic restarts.

## Architecture: Single vs Multi-Server

When creating a suite of related tools (e.g., an API wrapper), you must choose between a single consolidated server or multiple modular servers.

| Feature | Modular (Multi-Server) | Consolidated (Single-Server) |
| :--- | :--- | :--- |
| **Iteration** | **Sovereign**: Re-forge one tool without affecting others. | **Atomic**: One change requires re-forging the entire suite. |
| **Resilience** | **Isolated**: A crash in one tool doesn't stop the rest. | **Brittle**: One logic error can take down the whole server. |
| **Resources** | **Heavy**: One background process per tool (duplicate RAM). | **Efficient**: One process handles all tool requests. |
| **Workspace**| **Project-like**: `workstation/mcp/_name_/src/` (source) and `workstation/mcp/_name_/bin/` (binary). | **Clean**: One project, one source, one binary. |

> [!TIP]
> Use **Modular** during active development and debugging. Switch to **Consolidated** once the logic is stable to save system resources.

## Git Workflow & Source of Truth

The `workstation/mcp/` directory is the **Source of Truth** for your forged tools. Each tool follows a standard Nim project structure:

1.  **Draft in MCP src**: Directly edit or `write_file` to `workstation/mcp/_tool_name_/src/_tool_name_.nim`.
2.  **Git Tracking**: Since your `office/` is part of the NimClaw workspace, use `git add` to track your source files in their dedicated `workstation/mcp/` folders.
3.  **Forge from MCP Source**: Use `read_file` on your tracked source and pass it to `forge_mcp_tool`.
4.  **Modular Logic**: Use `include` in your main `src/*.nim` to split large consolidated servers into manageable files within the same directory.

## Lifecycle: Build vs Uninstall vs Delete

Understanding the lifecycle of a forged tool is critical for development safety:

1.  **Build & Install (`forge_mcp_tool`)**:
    - Compiles your code in `workstation/mcp/_name_/src/`.
    - Generates a binary in **`workstation/mcp/_name_/bin/`**.
    - Registers the server as active.
2.  **Uninstall (`purge_mcp_tool`)**:
    - Unregisters the server (stops the process).
    - Deletes only the **binary** in `/bin/`.
    - **PRESERVES your source code** in `src/`. This is the safe way to "stop" a tool.
3.  **Permanent Delete (`purge_mcp_tool` with `delete_source: true`)**:
    - Unregisters the server.
    - Permanently deletes the **entire directory**, including your source code. Use with caution!

> [!IMPORTANT]
> A successful `forge` makes the tool immediately ready for use. 
> - **Zero Setup**: `forge_mcp_tool` automatically creates all necessary directories (`src/`, `bin/`) for you. You do NOT need to call `create_dir`.
> - **Build from Source**: The `code` parameter is now **OPTIONAL**. If you already modified the source file in `workstation/mcp/_name_/src/`, you can simply call `forge_mcp_tool` with just the `name`. The tool will automatically use your disk changes as the build target.
> - **Atomic Updates**: If a tool with the same name exists, it will be safely replaced by the new version upon successful compilation. If a build fails, the old version remains active and no files are moved.

## Build Protection & Cleanup

The forge tool uses **Atomic Builds**. If your compilation fails, any temporary "junk" files (failed source/binaries) are automatically deleted, keeping your workspace clean. Only successful builds are promoted to the final `workstation/mcp/` directory.

## Rules

1. **Always `import mcp`** — this provides mcpServer, mcpTool, newStdioTransport, etc.
2. **`mcpServer(name, version):` takes TWO string args** — name and version.
3. **`mcpTool:` annotates a proc** — the proc name becomes the tool name.
4. **Doc comments (`##`) define the schema** — first line = description, `## - param: desc` lines define parameter descriptions.
5. **`when isMainModule:` block is REQUIRED** — creates the transport and starts the server.
6. Return type must be `string` — return JSON strings for structured data using `$(%*{...})`.
7. **Do NOT use hyphens in proc names** — Nim requires underscores (e.g., `my_tool` not `my-tool`).
8. **Use `include` for modularity** — split large single-server logic into multiple files within her `workstation/mcp/tool/src/` directory.
9. **MCP is Source-of-Truth** — track your `.nim` source directly in `workstation/mcp/_name_/src/` using Git.
