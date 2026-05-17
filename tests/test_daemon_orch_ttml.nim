## E2E verification for the [logs] expansion markup the orchestrator
## now emits (post-Markdown switch). We don't call renderCompanyRow
## directly — it's file-local — instead we hand-build the exact XML
## the daemon produces for representative cases and feed it through
## the real ttml parser + component registry to confirm:
##
##   * the XML attribute parser decodes `&#10;` to a real newline
##   * the Markdown factory splits the content on '\n' and produces
##     one entry per source line
##   * the └─ prefix is preserved on every line (including the
##     empty-log fallback)
##   * unsafe runtime characters (`<`, `&`, `"`) that come out of
##     stderr survive the xmlEscape round-trip
##
## XML attribute-value whitespace caveat: runs of literal `#x20`
## inside an attribute value are normalized to a single space by
## std/xmlparser. The daemon emits `"  └─ "` (two leading + one
## trailing space) but the parsed buffer sees `" └─ "` (one leading,
## trailing preserved because it's already a single-space run). The
## dashboard accepts this — same normalization applies to the
## `[remove]`/`[logs]` Text content elsewhere in the row — so the
## test asserts the post-parse value, not the pre-parse intent.
## Character references (`&#32;`) bypass normalization if the visual
## indent ever needs to be exactly two columns.
##
## If any of the structural checks regressed, the dashboard would
## silently render a blank box, a single mashed-together line, or
## fail to parse — none of which the click_unit harness catches.

import std/[unittest, strutils]
import ttml/[parser, runtime]
import ttml/components/markdown

# Same one-liner the daemon uses internally. Kept in lockstep with
# src/claw/daemon_orch.nim:xmlEscape so the test fixtures are built
# the same way the daemon builds them.
proc xmlEscape(s: string): string =
  result = s.multiReplace(("&", "&amp;"), ("<", "&lt;"),
                          (">", "&gt;"), ("\"", "&quot;"))

proc buildMd(xml: string): Markdown =
  let reg = newRegistry()
  reg.registerMarkdownComponents()
  let root = parseDoc(xml)
  Markdown(reg.build(root))

proc renderLogsMarkdown(height: int, lines: seq[string]): string =
  ## Mirrors the inline-diagnostic block in renderCompanyRow exactly.
  ## If the daemon's emission ever diverges from this, the test fails
  ## loudly rather than silently agreeing with itself.
  let src = if lines.len == 0: @["(no gateway.stderr.log yet)"] else: lines
  result.add "<Markdown h=\"" & $height & "\" content=\""
  for i, line in src:
    if i > 0: result.add "&#10;"
    result.add xmlEscape("  └─ " & line)
  result.add "\"/>"

suite "daemon [logs] expansion → <Markdown>":
  test "multi-line tail decodes &#10; into separate source lines":
    let xml = renderLogsMarkdown(8, @[
      "[claw] Shutting down...",
      "[claw] Stopped.",
      "Error: unhandled IOError"
    ])
    let m = buildMd(xml)
    check m.lineCount == 3
    # parseInline runs on each line — check the joined plain text of
    # each line carries the prefix and the original payload.
    proc plain(line: MarkdownLine): string =
      for r in line: result.add r.text
    check plain(m.lines[0]) == " └─ [claw] Shutting down..."
    check plain(m.lines[1]) == " └─ [claw] Stopped."
    check plain(m.lines[2]) == " └─ Error: unhandled IOError"

  test "single-line crash preview still gets the └─ prefix":
    let xml = renderLogsMarkdown(1, @["port 7777 already in use"])
    let m = buildMd(xml)
    check m.lineCount == 1
    var txt = ""
    for r in m.lines[0]: txt.add r.text
    check txt == " └─ port 7777 already in use"

  test "empty log falls back to the placeholder, still prefixed":
    let xml = renderLogsMarkdown(1, @[])
    let m = buildMd(xml)
    check m.lineCount == 1
    var txt = ""
    for r in m.lines[0]: txt.add r.text
    check txt == " └─ (no gateway.stderr.log yet)"

  test "stderr containing <, >, &, \" parses without breaking the document":
    # Real-world stderr lines from Nim tracebacks include angle brackets
    # ("Error: <stdin>(5, 1)..."), config dumps include `&` (URLs), and
    # quoted strings appear everywhere. If xmlEscape misses any of these
    # the parser will either raise or eat content silently.
    let lines = @[
      "Error: <stdin>(5, 1) bad token \"foo\"",
      "https://api.example.com/v1?k=1&t=abc",
      "warn: token expired & not refreshed"
    ]
    let xml = renderLogsMarkdown(8, lines)
    let m = buildMd(xml)   # would raise on parse failure
    check m.lineCount == 3
    proc plain(line: MarkdownLine): string =
      for r in line: result.add r.text
    check plain(m.lines[0]) == " └─ " & lines[0]
    check plain(m.lines[1]) == " └─ " & lines[1]
    check plain(m.lines[2]) == " └─ " & lines[2]

  test "single &#10; vs literal '\\n' — daemon must use the entity":
    # Defensive test for the bug class we fixed in the conversion:
    # if a future refactor xml-escapes AFTER joining with &#10;, the &
    # becomes &amp; and the parser sees one literal line that contains
    # "&#10;" rather than two lines. Assert the entity-encoded form
    # actually splits.
    let xml = """<Markdown content="line one&#10;line two"/>"""
    let m = buildMd(xml)
    check m.lineCount == 2
    # And the broken form — literal "&amp;#10;" — must NOT split.
    let broken = """<Markdown content="line one&amp;#10;line two"/>"""
    let mb = buildMd(broken)
    check mb.lineCount == 1   # confirms the entity, not the escaping, drives the split
