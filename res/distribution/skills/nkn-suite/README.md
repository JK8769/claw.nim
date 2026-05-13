# nkn-suite — NKN mainnet read-only ops

Vendor implementation of the payment-tool's vendor-action contract for
NKN — read-only on-chain inspection (balance, transaction lookup,
current block height).

The MESSAGING half of the NKN integration lives in-binary
(`src/claw/channels/nmobile.nim`) because it needs a persistent
NKN client connection. This skill covers the CHAIN-INSPECTION half —
pure RPC request/reply wrapped through `nkn-cli`.

Both halves use the same `nkn-cli` subprocess binary at
`<framework>/channels/bin/nkn-cli`.

## Setup

1. NKN mainnet uses public seed nodes — no auth needed.

2. Install this skill in your deployment's BASE.nims:
   ```nim
   skill "nkn-suite"
   ```

3. Rebuild and start the gateway. The skill auto-compiles to
   `workspace/skills/nkn-suite/bin/nkn-suite` and registers via MCP
   at gateway boot.

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
payment balance vendor=nkn-suite address=NKNxxx...
payment status  vendor=nkn-suite [tx_hash=...]
```

## Adding more read ops

Each new operation = one `mcpTool: proc <op>(...): JsonNode` block in
`src/nkn_suite.nim`. The proc body invokes `nkn-cli` and parses the
output. The MCP framework auto-generates the JSON schema from the
proc signature.

Likely candidates by priority:
- `get_address_balances` (addresses[]) → bulk balance lookup
- `get_block` (height_or_hash) → block details
- `get_block_count` → current chain height (alias for get_height)
- `subscribe_to_address` (address) → push notifications on incoming tx

Write ops (`transfer`, `send_tx`) require:
- Approval flow design (operator-in-the-loop)
- Spending limits + audit trail
- Wallet credential handling

These belong in Phase 4-6 of the payment work.

## Limitations

- Read-only by design (Phase 1).
- `get_transaction` is a stub pending nkn-sdk-go's lookup-by-hash API.
- Network-dependent — NKN seed nodes must be reachable.
