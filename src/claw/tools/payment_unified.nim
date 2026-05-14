## payment — channel-agnostic protocol verbs for value transfer.
##
## The third sibling in the comm/relationships taxonomy: chat is for
## conversational messages, mail for persistent messages, payment for
## value. Same pattern: tool exposes verbs, vendor rails plug in via the
## standard `mcp_<vendor>_<op>` dispatch. Each vendor is a payment-rail
## skill (nkn-suite for NKN, future: btc, lightning, usdc-base, etc.).
##
##   method=balance  vendor=X address=…   — wallet balance lookup
##   method=status   vendor=X [tx_hash=…] — chain reachability + tx lookup
##   method=history  vendor=X address=… [since=…] — recent transactions
##
## Phase 1 (this code): READ-ONLY ops. No transfer / send / write
## actions yet — those need an approval-flow design pass and a
## per-agent / per-vendor spending-limit system that doesn't exist
## yet. Send / receive land in Phase 4-6 of the payment work.
##
## Vendor rails (each is a skill in res/distribution/skills/):
##   nkn-suite      — NKN mainnet (Phase 1 today)
##   btc            — Bitcoin (future)
##   lightning      — Lightning Network (future)
##   usdc-base      — USDC on Base (future)
##   usdc-tron      — USDC on Tron (future)

import std/[json, asyncdispatch, tables, strutils]
import ./types
import ./spec
import ./registry
import ./vendor_dispatch

const ToolSpec* = spec(
  name = "payment",
  description = "Value-transfer protocol verbs (Phase 1: READ-ONLY — " &
                "balance, status, history). Routes via vendor rails " &
                "(nkn-suite today; btc/lightning/usdc-* future). For " &
                "real-time messaging see chat; persistent messaging " &
                "see mail; this is the third sibling for value.",
  tags = @["payment", "finance", "wallet", "core"],
  searchKeywords = @["payment", "balance", "wallet", "transaction",
                     "tx", "status", "history", "nkn", "btc",
                     "lightning", "usdc", "transfer", "money", "value"],
  domain = "payment",
  default = false,  # operator opts in per company; not auto-granted
  heartbeatSafe = false,
  externalAllowed = false,  # external read sees own balances; no
                            # external write until approval flow lands
  category = "finance",
)

type
  PaymentTool* = ref object of Tool
    reg*: ToolRegistry  ## live registry — scanned per-call to find
                         ## payment-rail vendor MCP tools
                         ## (mcp_<vendor>_<op>).

proc newPaymentTool*(reg: ToolRegistry = nil): PaymentTool =
  PaymentTool(reg: reg)

method name*(t: PaymentTool): string = "payment"

method description*(t: PaymentTool): string =
  "Value-transfer (Phase 1: READ-ONLY).\n\n" &
  "Actions:\n" &
  "  balance vendor=X address=…       — wallet balance for an address\n" &
  "  status  vendor=X [tx_hash=…]     — chain reachability check; with\n" &
  "                                     tx_hash, transaction lookup\n" &
  "  history vendor=X address=… [since=…] — recent transactions for an address\n\n" &
  "Vendors (rails) — install via `skill \"<vendor>-suite\"`:\n" &
  "  nkn-suite    — NKN mainnet (today)\n" &
  "  btc          — Bitcoin (future)\n" &
  "  lightning    — Lightning Network (future)\n" &
  "  usdc-base    — USDC on Base (future)\n\n" &
  "Phase 2+ (send / receive / transfer) needs an approval flow + " &
  "spending limits — not shipped yet. For now, these read ops give " &
  "operators visibility into wallets through a clean agent surface."

method parameters*(t: PaymentTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "method": {
        "type": "string",
        "enum": ["balance", "status", "history"],
        "description": "Operation. balance/status/history are read-only."
      },
      "vendor": {
        "type": "string",
        "description": "Payment rail (nkn-suite, btc, lightning, " &
                       "usdc-base, usdc-tron, …). Each is a skill — " &
                       "install via `skill \"<vendor>\"` in BASE.nims."
      },
      "address": {
        "type": "string",
        "description": "balance/history — wallet address (vendor-specific " &
                       "format: NKN address for nkn-suite, bech32 for btc, " &
                       "hex 0x… for usdc-*, etc.)."
      },
      "tx_hash": {
        "type": "string",
        "description": "status — transaction hash to look up. Without " &
                       "tx_hash, status returns chain reachability + " &
                       "current height as a probe."
      },
      "since": {
        "type": "string",
        "description": "history — earliest timestamp / block to include " &
                       "(ISO 8601 or block number, vendor-specific). " &
                       "Default: vendor's natural history window."
      }
    },
    "required": %["action", "vendor"]
  }.toTable

# ── action handlers ─────────────────────────────────────────────────

proc doBalance(t: PaymentTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.reg.isNil:
    return """{"error":"payment_tool_not_bound_to_registry"}"""
  if not args.hasKey("vendor"):
    return """{"error":"missing_vendor"}"""
  if not args.hasKey("address"):
    return """{"error":"missing_address"}"""
  let vendor = args["vendor"].getStr()
  var fwd: Table[string, JsonNode]
  fwd["address"] = args["address"]
  return await dispatchToVendor(t.reg, vendor, "get_balance", fwd)

proc doStatus(t: PaymentTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.reg.isNil:
    return """{"error":"payment_tool_not_bound_to_registry"}"""
  if not args.hasKey("vendor"):
    return """{"error":"missing_vendor"}"""
  let vendor = args["vendor"].getStr()
  if args.hasKey("tx_hash") and args["tx_hash"].getStr().len > 0:
    var fwd: Table[string, JsonNode]
    fwd["hash"] = args["tx_hash"]
    return await dispatchToVendor(t.reg, vendor, "get_transaction", fwd)
  # No tx_hash → chain reachability check via current height.
  return await dispatchToVendor(t.reg, vendor, "get_height", initTable[string, JsonNode]())

proc doHistory(t: PaymentTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if t.reg.isNil:
    return """{"error":"payment_tool_not_bound_to_registry"}"""
  if not args.hasKey("vendor"):
    return """{"error":"missing_vendor"}"""
  if not args.hasKey("address"):
    return """{"error":"missing_address"}"""
  let vendor = args["vendor"].getStr()
  var fwd: Table[string, JsonNode]
  fwd["address"] = args["address"]
  if args.hasKey("since"): fwd["since"] = args["since"]
  return await dispatchToVendor(t.reg, vendor, "get_history", fwd)

# ── dispatch ────────────────────────────────────────────────────────

method execute*(t: PaymentTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not (args.hasKey("method") or args.hasKey("action")):
    return """{"error":"missing_action"}"""
  let action = getMethodArg(args).toLowerAscii()
  case action
  of "balance": return await doBalance(t, args)
  of "status":  return await doStatus(t, args)
  of "history": return await doHistory(t, args)
  else:
    return """{"error":"unknown_action","action":"""" & action & """"}"""
