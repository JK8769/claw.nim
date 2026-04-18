import std/unittest
import ../src/nimclaw/config
import ../src/nimclaw/tools/web
import std/[json, tables, asyncdispatch, strutils]

suite "WebSearch Config tests":
  test "defaultConfig has correct websearch fallbacks":
    let cfg = defaultConfig()
    check cfg.tools.web.search.provider == "auto"
    check cfg.tools.web.search.fallback_providers == @["duckduckgo"]
    check cfg.tools.web.search.max_results == 5

suite "DuckDuckGo API Extractor tests":
  test "extracts simple abstract results correctly":
    let jsonStr = """
    {
      "Heading": "Nim Programming Language",
      "AbstractText": "Nim is a statically typed compiled systems programming language.",
      "AbstractURL": "https://nim-lang.org/",
      "RelatedTopics": []
    }
    """
    let reqNode = parseJson(jsonStr)
    let res = extractDuckDuckGoResults("Nim", 5, reqNode)
    # TDD Expectation: It extracts the abstract
    check res.contains("1. Nim Programming Language")
    check res.contains("https://nim-lang.org/")
    check res.contains("Nim is a statically typed compiled systems programming language.")

  test "extracts related topics correctly":
    let jsonStr = """
    {
      "Heading": "",
      "AbstractText": "",
      "AbstractURL": "",
      "RelatedTopics": [
        {
          "Text": "Nim (programming language)",
          "FirstURL": "https://duckduckgo.com/Nim_(programming_language)"
        },
        {
          "Text": "Nim - mathematical game of strategy",
          "FirstURL": "https://duckduckgo.com/Nim"
        }
      ]
    }
    """
    let reqNode = parseJson(jsonStr)
    let res = extractDuckDuckGoResults("Nim", 5, reqNode)
    # TDD Expectation: It extracts the topics
    check res.contains("1. Nim (programming language)")
    check res.contains("https://duckduckgo.com/Nim_(programming_language)")
    check res.contains("2. Nim - mathematical game of strategy")
    check res.contains("https://duckduckgo.com/Nim")
