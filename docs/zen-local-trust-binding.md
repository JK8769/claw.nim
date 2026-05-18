# Local creator auto-bind for the zen channel

**Status**: Proposal — not implemented. Awaiting review.

**Author**: Drafted by Claude after a focused read of the cortex / binding / gateway-auth code paths. Cite-checked against the source.

## Problem

When the zen channel connects from the same OS user that ran `claw create` for the company, the invite-code roundtrip currently required by the bind flow is friction without security gain. The OS already authenticated the user (file permissions, process ownership). Asking them to issue + paste an invite code adds a step that protects against nothing in this specific case.

For comparison: a Feishu/QQ/nMobile user needs the invite code because they're authenticated by an external platform that claw doesn't trust transitively. A zen user on the same machine + same OS account is authenticated by the operating system, which claw already implicitly trusts (it reads BASE.json, spawns gateways, etc.).

## Goal

When a zen client connects to a gateway:

1. The gateway verifies the connecting process's OS UID via `SO_PEERCRED` / `LOCAL_PEERCRED` on the socket. **This is the actual security boundary** — the `user` string zen sends in `chat.connect` is informational; the kernel-reported UID is unspoofable.
2. If the peer UID matches the UID that ran `claw create` for this company (captured at create time), and the company's SuperAdmin entity has no `zen` binding yet, the gateway stamps `ent.identifiers["zen"] = "local:<user>"` directly — same mutation `tryBind` makes after a successful invite-code redemption — and persists.
3. Subsequent messages from this zen connection resolve to the SuperAdmin entity via the normal `resolveSenderEntity` path. RBAC, tool grants, audit all behave identically to the post-invite state.

The auto-bind happens **once**, on first connect from the creator. After that the binding is in `BASE.json` like any other channel binding. The invite-code path still exists for every non-trivial case (different OS user, different machine, remote zen).

## Non-goals

- **Default-on for ALL connections** — only the OS UID that created the company gets auto-bound. Other zen connections still go through the standard invite flow.
- **Bypass the auth gate without an entity** — the message must resolve to a real WorldEntity so RBAC/audit work correctly. We don't reuse the `system:` prefix.
- **Auto-create the SuperAdmin entity** — the SuperAdmin already exists from `claw create` (clawdsl.nim:1319–1343). We only add an identifier to it.

## Required changes

### 1. Record creator UID at `claw create` (claw.nim around the create flow)

`claw create` writes BASE.nims + initial state. Add a `creator_uid` field to the company state file (BASE.json or a sidecar).

```nim
# At create time:
graph.creatorUid = getuid().int    # numeric UID is portable across hostname changes
graph.saveWorld()
```

Schema addition in `cortex.nim` `WorldGraph`:

```nim
WorldGraph* = ref object
  ...
  creatorUid*: int                 # OS UID that ran `claw create`; 0 if unset
```

JSON serialization in `loadWorld` / `saveWorld` follows the existing pattern.

### 2. Read peer credentials on the zen channel (channels/zen.nim)

After successful socket connect in `tryConnect`, query the peer's OS UID:

```nim
# macOS: LOCAL_PEERCRED via getsockopt
# Linux: SO_PEERCRED via getsockopt
proc getPeerUid(s: Socket): int =
  ## Returns kernel-reported UID of the peer (zen process) for a
  ## connected Unix socket. Returns -1 on platforms / errors where
  ## not supported; caller treats -1 as "untrusted, fall through to
  ## invite flow."
```

Add `peerUid: int` to `ZenChannel`. Populate after `tryConnect` succeeds.

### 3. Auto-bind path in the message-intake (channels/zen.nim around line 128)

Before calling `c.handleMessage`, check if this connection qualifies for auto-bind:

```nim
# In the reader loop, when a chat.message arrives:
let myUid = getuid().int
let trusted = c.peerUid > 0 and c.peerUid == myUid and
              graph.creatorUid > 0 and c.peerUid == graph.creatorUid

if trusted:
  let superAdminID = findSuperAdminEntity(graph)  # scan entities for role == "superadmin"
  if uint32(superAdminID) > 0:
    let ent = graph.entities[superAdminID]
    if not ent.identifiers.hasKey("zen"):
      # First connect — stamp the binding. Same mutation tryBind does.
      ent.identifiers["zen"] = "local:" & getEnv("USER")
      graph.entities[superAdminID] = ent
      graph.saveWorld()
      persistPersonIdentifiers(graph, workspace)
      logInfo("zen: auto-bound creator local:" & getEnv("USER") &
              " to SuperAdmin nc:" & $superAdminID.int)
```

After this point, `resolveSenderEntity(graph, msg)` finds the SuperAdmin entity via its `zen` identifier. The gateway auth gate (`gateway.nim:3115-3142`) passes. The agent dispatch sees `role = "superadmin"` and grants the appropriate tool/RBAC permissions.

### 4. No changes to the gate or RBAC

The existing `gateway.nim:3115-3142` gate continues to work unchanged — after step 3, `resolveSenderEntity` returns a valid entity ID for the message, `recognized = true` falls out of the existing check, and the rest of the pipeline proceeds normally.

## Trust model

| Signal | What it proves | Where it's checked |
|---|---|---|
| `c.peerUid` (kernel-reported) | The connecting process really IS that OS user | `getPeerUid` via `LOCAL_PEERCRED` |
| `graph.creatorUid` (recorded at create time) | This OS user created this company | Capture at `claw create`, persist in `BASE.json` |
| `peerUid == creatorUid` | The current connector and the creator are the same OS account | At first message intake |
| `peerUid == getuid()` (daemon's own UID) | The connection is from the same OS user the daemon runs as | Extra defence; ensures the daemon hasn't been compromised to accept a fake UID |

All three must match for auto-bind. Each one is independently verifiable; none can be spoofed by a process running as a different OS user.

## What this is NOT

- **Not a config-override path.** No "auto-trust this user" knob in BASE.nims. The creator-uid is captured automatically at `claw create` and is not editable. Changing it requires re-creating the company.
- **Not transitive across machines.** `creatorUid` is a numeric UID. If you `claw create` on laptop A as UID 501, then run the same company directory on machine B where UID 501 maps to a different person, no auto-bind happens (because the daemon's `getuid()` on B is different, OR you'd be on a fresh machine where UID 501 is actually you again — both cases self-correct).
- **Not multi-user.** Only one OS-creator per company. A second OS user on the same machine wanting SuperAdmin access uses the normal invite flow.
- **Not "the operator authorized this in code."** The operator's authorization is the act of running `claw create` themselves. No AI-authored identity binding.

## Implementation order

1. Add `creatorUid` to `WorldGraph`, serialize in `saveWorld` / `loadWorld`. (cortex.nim)
2. Capture `getuid()` at `claw create` time. (claw.nim — find the create command handler)
3. Add `getPeerUid` helper for Unix sockets (channels/zen.nim or a new util).
4. Add `peerUid: int` field + populate it in `tryConnect`. (channels/zen.nim)
5. Add auto-bind logic in the message-intake path. (channels/zen.nim — before the existing `handleMessage` call)
6. Test: `claw create FooCorp`, open zen as the same OS user, send a message. Expect no invite challenge. Verify `BASE.json` has `identifiers["zen"] = "local:<user>"` on the SuperAdmin entry.
7. Negative test: `su` to another OS user, run zen, send a message. Expect normal invite challenge.

Total surface: ~80 lines across `cortex.nim`, `claw.nim`, `channels/zen.nim`. No changes to gateway auth, RBAC, or the bind protocol itself.

## Open questions

- **`creator_uid: 0` semantics.** Pre-existing companies (created before this change) have no recorded creator. Default behaviour for those: no auto-bind, invite flow as today. Adding the field on first save is automatic; we just need to make sure the absent field deserialises as `0` and the trust check rejects `0` matches.
- **`getuid()` returning `0` (root).** Edge case worth handling explicitly: if `creatorUid == 0` and `peerUid == 0`, the trust check would pass. Probably correct (root is root) but worth an explicit comment.
- **What does `pruneGuestsAcrossOffices` do?** Used by the standard bind path. Worth checking if we need to call it in the auto-bind path too, or if it's invite-specific cleanup.

## What I (the AI) will NOT do

Per the project's safety convention around identity state:

- I won't make this change without an operator review of this doc.
- I won't add a config-file knob to disable the safety boundary (no "trust any zen connection" override).
- I won't auto-create entities — only stamp identifiers onto entities that already exist from `claw create`.
- I won't mint invite codes or simulate redemption paths.

## Cite-checks

- WorldEntity + identifiers table: `src/claw/agent/cortex.nim:35-67`
- `resolveSenderEntity` + `resolveUserGraph`: `src/claw/gateway.nim:757`, `src/claw/agent/cortex.nim:936`
- Auth gate: `src/claw/gateway.nim:3115-3142`
- Agent dispatch using entity role: `src/claw/agent/loop.nim:2380-2389`
- `tryBind` mutations: `src/claw/agent/binding.nim:197-243`
- SuperAdmin bootstrap at create time: `src/claw/clawdsl.nim:1319-1343`
- SuperAdmin invite issuance at gateway startup: `src/claw/agent/binding.nim:73`
- `saveWorld`: `src/claw/agent/cortex.nim:583`
