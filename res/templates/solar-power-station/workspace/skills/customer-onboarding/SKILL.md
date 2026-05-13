---
name: customer-onboarding
version: 1.0.0
description: "Verify and invite a new customer for solar plant monitoring: check Known Entities first; if not present, mint via `social action=invite`; quote the tool result verbatim. Anti-fabrication discipline: no nc: ids asserted from memory."
loading: lazy
operations:
  - verify
  - invite
  - onboard
  - lookup
keywords:
  - invite
  - onboard
  - new customer
  - register
  - 邀请
  - 注册
  - 新用户
requires:
  tools:
    - social
    - reply
---

Workflow for verifying a customer's status and minting an invite
if needed. Encodes the anti-fabrication discipline as concrete
steps — designed to prevent the failure mode where an agent
asserts an `nc:` id from memory without verification.

## When to load this skill

- An operator says "invite @SomeoneNew" (or zh: "邀请...")
- An operator asks "is X already a customer?"
- Before any operation that would mint a new identity in the graph

The customer's own redeem flow uses `social action=redeem` directly,
not this skill — this skill is operator-facing.

## Workflow

1. **Resolve the user's identifier first.** From the @-mention
   metadata in the operator's message if available. If the mention
   is just typed text (`@LUBIN` with no metadata), ask the
   operator for the open_id / username / equivalent.

2. **Check Known Entities** in your system prompt for the resolved
   identifier. The prompt's `## Known Entities` section lists
   every Person entity with their channel identifiers (e.g.,
   `feishu:cli_xxx=ou_yyy`). Search by the literal open_id /
   username, not by display name (display names drift).

3. **If Known Entities has a match**: report the existing `nc:`
   id directly. **STOP — do not mint.** Quote the matched line:

   ```
   @SomeoneNew is already onboarded as nc:7.
   (Verified via Known Entities — feishu:open_id=ou_abc123)
   ```

4. **If Known Entities doesn't match**, optionally call
   `social action=query` for a second-source check (search by
   display name in case the identifier resolution was incomplete).

5. **Call `social action=invite`** with the resolved identifier:
   - If the customer is already onboarded (the tool detects this),
     it returns details about their existing identity — quote the
     response verbatim and STOP.
   - If a new invite was minted, the tool returns the bundled
     `nc:X/CODE` string. Quote the FULL response.

6. **Confirm the operator can share** the bundled string with the
   prospective customer. The customer redeems via
   `claw redeem nc:X/CODE-...`.

## Anti-fabrication discipline (the hard rule)

**NEVER assert an `nc:` id you didn't read directly from a tool
result or the Known Entities block in your prompt this turn.**

If you find yourself about to write "X is nc:N" or "X is already
registered" without seeing the literal evidence this turn, STOP.

Acceptable paths:

- Quote the open_id you DO see, ask the operator to confirm
- Call `social action=query` to look up the name
- Call `social action=invite` and let it fail-loudly if the
  identity already exists

The framework cannot distinguish your guess from a verified
lookup. The operator will trust your assertion. A fabricated
`nc:` id can route messages to the wrong agent (real failure mode
in production: an agent claimed "X is nc:2" when nc:2 was an AI
agent, not a customer — the operator only caught it later).

## Output shapes (the only valid replies)

Either:

```
Customer @SomeoneNew is already onboarded as nc:7.
(Verified via Known Entities — feishu:open_id=ou_abc123)
```

OR:

```
New invite minted for @SomeoneNew:
  nc:8 / Bundle: nc:8/CODE-XYZ789

Share the bundle. They redeem via:
  claw redeem nc:8/CODE-XYZ789
```

OR (when you genuinely can't verify):

```
I can't verify @SomeoneNew without an identifier. Can you share
their open_id or @-mention them with metadata? Otherwise I can
proceed via create_customer_invite, which will either succeed
(if new) or fail-loudly (if already registered) — your call.
```

Never anything else. No "I think they're already registered."
No "let me assume they're new."

## Anti-patterns

- **Skipping Known Entities check** → fabrication risk
- **Asserting `nc:` from pattern-match** → fabrication
- **Paraphrasing the tool output** → loses verifiability
- **Acting on partial info** ("I'll mint an invite, you can sort
  out the duplicate later") → creates ghost identities in the
  graph
- **Inventing identifiers** (`@LUBIN → open_id=ou_LUBIN_001`) →
  the open_id space isn't human-readable; you can't guess them
