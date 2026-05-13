---
name: nkn-suite
version: 0.1.0
description: "NKN mainnet vendor — read-only on-chain ops (balance, transaction lookup, current height). Wraps the nkn-cli subprocess via MCP stdio. Reached by agents through `payment balance vendor=nkn-suite address=…` etc. Companion to the in-binary `channels/nmobile.nim` (NKN messaging — needs persistent connection)."
contract_version: 1
requires:
  tools: []
  deps:
    - package: nim
      manager: system
    - package: go
      manager: system
  env: []
---

# nkn-suite

NKN mainnet vendor implementation — read-only on-chain inspection
(balance, transaction lookup, current block height). Mirrors the
lark-suite pattern: messaging stays in-binary at `channels/nmobile.nim`
(persistent NKN client connection); request/reply chain RPCs live
here as a vendor MCP server.

## Architecture parallel

```
                     Lark / Feishu              NKN / nMobile
─────────────────────────────────────────────────────────────────
Messaging (in-binary)  channels/feishu.nim   channels/nmobile.nim
Productivity (skill)   lark-suite            nkn-suite (this skill)
Subprocess wrapped     lark-cli              nkn-cli
Reached via            channel docs vendor=  payment balance vendor=
                       lark-suite             nkn-suite
```

## Status: read-only ops only (Phase 1)

Currently exposes the three read-only on-chain ops. NO transfer / write
operations yet — those need an approval-flow design pass first (see
`docs/payment-design-notes.md` when the design lands).

| Tool | Args | Returns | Risk |
|---|---|---|---|
| `get_balance` | `address: string` | `{balance: string}` (NKN tokens) | Low — pure read |
| `get_height` | `{}` | `{height: int}` (current block) | Low — pure read |
| `get_transaction` | `hash: string` | `{transaction: …}` (placeholder — SDK gap noted in nkn-cli source) | Low — pure read when wired |

Future Phase 2 (transfer, send_tx, etc.) requires:
- nkn-cli Go extension for transfer ops
- payment-tool approval flow (operator-in-the-loop)
- Spending limits + audit trail
- Recovery flow for compromised agents

## Setup

1. NKN mainnet uses public seed nodes — no auth, no API key. The
   bundled `nkn-cli` (channels/bin/nkn-cli) handles the RPC.

2. Install in your deployment's BASE.nims:
   ```nim
   skill "nkn-suite"
   ```

3. Rebuild (`claw co update`). The skill auto-compiles and registers
   via MCP at gateway boot.

## Verifying

```bash
claw tools list | grep mcp_nkn-suite_

# Should see:
#   mcp_nkn-suite_get_balance
#   mcp_nkn-suite_get_height
#   mcp_nkn-suite_get_transaction
```

## Agent-facing usage (via payment tool)

```
# Check balance for an address
payment balance vendor=nkn-suite address=NKNxxx...

# Current chain height (sanity check that the chain is reachable)
payment status  vendor=nkn-suite

# Transaction lookup by hash
payment status  vendor=nkn-suite tx_hash=0xabc...
```

## Limitations

- Network dependence: requires the NKN mainnet seed nodes to be
  reachable from the gateway host. "all rpc request failed" indicates
  no seed node responded — usually transient (a different seed picks
  up on retry) but persistent failure means firewalled / offline.
- get_transaction is a stub pending nkn-sdk-go's lookup-by-hash API.
  Falls back to a friendly error pointing at the REST endpoint shape.
- Read-only by design (Phase 1). Transfer / write ops deferred until
  the payment approval-flow design lands.
