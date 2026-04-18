import std/[unittest, json]
import ../src/nimclaw/schema

suite "JSON Schema Cleaner":
  test "Removes unsupported keys for Gemini":
    let j = %*{
      "type": "object",
      "properties": {
        "x": {"type": "string"}
      },
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#",
      "allOf": [{"type": "string"}]
    }
    let cleaned = cleanForStrategy(j, Gemini)
    check cleaned.hasKey("type")
    check cleaned.hasKey("properties")
    check not cleaned.hasKey("additionalProperties")
    check not cleaned.hasKey("$schema")
    check not cleaned.hasKey("allOf")

  test "Removes fewer keys for OpenAI":
    let j = %*{
      "type": "object",
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#",
      "allOf": [{"type": "string"}]
    }
    let cleaned = cleanForStrategy(j, OpenAI)
    check cleaned.hasKey("additionalProperties") # OpenAI allows this
    check not cleaned.hasKey("$schema")
    check cleaned.hasKey("allOf") # OpenAI allows this

  test "Resolves $ref and maintains metadata":
    let j = %*{
      "$defs": {
        "Person": {
          "type": "object",
          "properties": {"name": {"type": "string"}}
        }
      },
      "type": "object",
      "properties": {
        "author": {
          "description": "The author",
          "$ref": "#/$defs/Person"
        }
      }
    }
    let cleaned = cleanForStrategy(j, Gemini)
    check not cleaned.hasKey("$defs")
    let author = cleaned["properties"]["author"]
    check author["description"].getStr() == "The author"
    check author["type"].getStr() == "object"
    check author["properties"]["name"]["type"].getStr() == "string"
    check not author.hasKey("$ref")

  test "Resolves $ref arrays properly":
    let j = %*{
      "definitions": {
        "StringList": {
          "type": "array",
          "items": {"type": "string"}
        }
      },
      "type": "object",
      "properties": {
        "tags": {
          "$ref": "#/definitions/StringList"
        }
      }
    }
    let cleaned = cleanForStrategy(j, Anthropic)
    check not cleaned.hasKey("definitions")
    let tags = cleaned["properties"]["tags"]
    check tags["type"].getStr() == "array"
    check tags["items"]["type"].getStr() == "string"

  test "Prevents circular reference infinite loops":
    let j = %*{
      "$defs": {
        "Node": {
          "type": "object",
          "properties": {
            "child": {"$ref": "#/$defs/Node"}
          }
        }
      },
      "type": "object",
      "properties": {
        "root": {"$ref": "#/$defs/Node"}
      }
    }
    let cleaned = cleanForStrategy(j, Gemini)
    let root = cleaned["properties"]["root"]
    check root["type"].getStr() == "object"
    # child object stops infinite recursion and returns an empty placeholder schema
    check root["properties"]["child"].hasKey("type") == false
    
  test "Extracts Null from anyOf into standard lists for Gemini":
    let j = %*{
      "type": "object",
      "properties": {
        "optional_name": {
          "description": "A name or null",
          "anyOf": [
            {"type": "string"},
            {"type": "null"}
          ]
        }
      }
    }
    let cleaned = cleanForStrategy(j, Gemini)
    let opt = cleaned["properties"]["optional_name"]
    check opt["description"].getStr() == "A name or null"
    check not opt.hasKey("anyOf")
    let t = opt["type"]
    check t.kind == JArray
    check t[0].getStr() == "string"
    check t[1].getStr() == "null"
    
  test "Flattens literal union const and enum strings for Gemini":
    let j = %*{
      "type": "object",
      "properties": {
        "status": {
          "oneOf": [
            {"type": "string", "const": "active"},
            {"type": "string", "const": "inactive"},
            {"type": "string", "enum": ["pending", "deleted"]}
          ]
        }
      }
    }
    let cleaned = cleanForStrategy(j, Gemini)
    let status = cleaned["properties"]["status"]
    check status.hasKey("enum")
    let e = status["enum"]
    check e.kind == JArray
    check e[0].getStr() == "active"
    check e[1].getStr() == "inactive"
    check e[2].getStr() == "pending"
    check e[3].getStr() == "deleted"
    check not status.hasKey("oneOf")
