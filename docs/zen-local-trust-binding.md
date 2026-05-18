# Local trust auto-bind for the zen channel

**Status**: Proposal v2 — not implemented. Awaiting review.

**Author**: Drafted by Claude after a focused read of the cortex / binding / gateway-auth code paths. v2 reflects operator feedback rejecting the recorded `creator_uid` approach (which broke under USB-transfer and false-matched under UID collision) in favour of pure runtime UID-match.

## Problem

When the zen channel connects from the same OS user that runs the claw gateway, the invite-code roundtrip currently required by the bind flow is friction without security gain.

If you have shell access as the OS user that owns the gateway process, you can already kill the daemon, read/write `BASE.json`, modify `bindings.json`, or restart with any config you want. The bind flow doesn't add a security layer above that — it's there for *external* channels (Feishu/QQ/etc.) where the user is authenticated by another platform that claw doesn't transitively trust. Zen is local; the OS already did the auth.

## Goal

Auto-bind a zen client to the company's SuperAdmin when **the zen process and the gateway process run as the same OS user**.

That's the entire trust check. One condition, two unspoofable signals.

## Trust model

```nim
let myUid = getuid().int                  # daemon's own UID
let peerUid = getPeerUid(zenSocket).int   # zen's UID via LOCAL_PEERCRED
let trusted = peerUid >= 0 and peerUid == myUid
```

**Why this is sound**: at the OS level, if `peerUid == myUid`, the same human is in control of both processes. Any access control claw could impose on top of this is moot — they can already manipulate the gateway, the workspace, and the cortex graph via direct file/process access.

**Why we don't need workspace ownership**: the daemon already had to read `BASE.json` to spawn the gateway. If the daemon could read it, the user running the daemon has access to it. No additional check on file ownership adds information.

**Why we don't need a recorded creator field**: it doesn't survive `cp -r` to another machine (UID changes), and it false-matches under cross-machine UID collisions. The runtime UID-match is local-correct without any persisted state.

| Scenario | Daemon UID | Zen peer UID | Trust? | Outcome |
|---|---|---|---|---|
| Alice creates + chats on laptop A as `alice` | 501 | 501 | ✓ | auto-bind |
| Bob USB-receives, runs daemon + zen on B as `bob` | 1000 | 1000 | ✓ | auto-bind (Bob is the operator on B) |
| Multi-user box: `alice` runs daemon, `bob` runs zen | 501 | 1000 | ✗ | invite flow |
| `sudo claw daemon start` + zen as alice | 0 | 501 | ✗ | invite flow |
| Same user, multiple zen sessions | 501 | 501 | ✓ each time (idempotent — see "auto-bind action" below) |

## Auto-bind action (only when trusted, and only when needed)

Same mutation `tryBind` performs after a successful invite-code redemption, applied to the first SuperAdmin entity that has **no `zen` binding yet**:

```nim
proc findUnboundSuperAdmin(graph: WorldGraph): WorldEntityID =
  ## Scan for a Person with role == "superadmin" and no zen binding.
  ## If all SuperAdmins are already bound on the `zen` channel, return 0.
  ## In that case skip auto-bind — either this user is already in the
  ## graph, or there are no slots left and the operator should use the
  ## standard invite flow to add another admin.
  for id, ent in graph.entities:
    if ent.kind == ekPerson and
       ent.role.toLowerAscii == "superadmin" and
       not ent.identifiers.hasKey("zen"):
      return id
  WorldEntityID(0)

# On first zen connect, after the trust check passes:
let target = findUnboundSuperAdmin(graph)
if uint32(target) > 0:
  var ent = graph.entities[target]
  ent.identifiers["zen"] = "local:" & getEnv("USER")
  graph.entities[target] = ent
  graph.saveWorld()
  persistPersonIdentifiers(graph, workspace)
  logInfo("zen: auto-bound trusted local user local:" &
          getEnv("USER") & " to SuperAdmin nc:" & $target.int)
```

**Idempotent**: on a second zen connect, `findUnboundSuperAdmin` returns 0 (the SuperAdmin already has the `zen` binding), so the auto-bind is a no-op. The existing `resolveSenderEntity` path then finds the entity by its identifier and lets the message through — same as a normal post-bind connection.

**Bounded**: only ONE SuperAdmin gets auto-bound per company. If multiple SuperAdmins exist, only the first unbound one is selected. Additional SuperAdmin bindings still go through the standard invite flow — this aligns with `ensureSuperAdminBindings` (binding.nim:73), which also issues codes only for entities with `identifiers.len == 0`.

## What this is NOT

- **Not transitive trust across machines.** Each machine independently establishes trust at runtime. No state crosses the network.
- **Not multi-user.** Only the daemon's owner gets auto-bound. Other OS users (or remote zen) use the standard invite flow.
- **Not a config-file override.** There's no "auto-trust all zen" toggle. The trust is built into the protocol semantics — you'd disable it by running the daemon as a different user than zen, which is what would happen accidentally if you don't want auto-bind anyway.
- **Not retroactive.** Companies created before this change behave identically — auto-bind triggers on first zen connect when the UID check passes, regardless of when the company was created.
- **Not for the `system:` prefix.** That's internal framework traffic with no RBAC. We bind to a real `local:<user>` identifier that goes through normal cortex resolution.

## Required changes

| File | Change | Lines |
|---|---|---|
| `channels/zen.nim` | Add `getPeerUid(sock: Socket): int` helper using `LOCAL_PEERCRED` (macOS) / `SO_PEERCRED` (Linux) | ~15 |
| `channels/zen.nim` | Add `peerUid: int` field on `ZenChannel`; populate it after successful `tryConnect` | ~5 |
| `channels/zen.nim` | In the message-intake path (around line 128), check trust + call auto-bind helper | ~15 |
| `agent/binding.nim` (or a new `local_trust.nim`) | `proc autoBindLocalCreator(graph, workspace, user): bool` — encapsulates the unbound-SuperAdmin lookup + mutation | ~25 |

Total: ~60 lines, no schema changes, no `claw create` changes, no auth-gate changes, no RBAC changes.

## What I (the AI) will NOT do

Per the project's safety convention around identity state:

- I won't write this code until you sign off on this v2 doc.
- I won't add a config-file knob that disables the UID check ("trust any zen connection"). The UID check IS the safety boundary; nothing weaker should exist.
- I won't bind to anything other than an *existing* SuperAdmin entity with no current `zen` binding. No entity creation, no role changes, no overwriting an existing binding.
- I won't mint invite codes or simulate redemption.

## Open questions

1. **Logging.** Should the auto-bind action go to admin.log with a recognisable tag (so a security audit can find it later)? I'd say yes: log at INFO with `auto_bind=true` so it's distinguishable from manual redemptions.
2. **`pruneGuestsAcrossOffices` call.** The standard bind path calls this after stamping. Worth verifying whether the auto-bind path needs it — probably yes, since there might be a guest `local:<user>` entry from a prior unrecognised connection.
3. **Failure handling.** If `findUnboundSuperAdmin` returns 0 AND the user is currently unrecognised, the trust check passed but nothing happened. Should we log an explanatory line (e.g., "trusted local user but all SuperAdmins already bound — falling through to invite flow")? Yes — silent failures here would be confusing.

## Cite-checks

- WorldEntity + identifiers table: `src/claw/agent/cortex.nim:35-67`
- `resolveSenderEntity` + `resolveUserGraph`: `src/claw/gateway.nim:757`, `src/claw/agent/cortex.nim:936`
- Auth gate: `src/claw/gateway.nim:3115-3142`
- Agent dispatch using entity role: `src/claw/agent/loop.nim:2380-2389`
- `tryBind` mutations as the reference shape: `src/claw/agent/binding.nim:197-243`
- SuperAdmin bootstrap at create time: `src/claw/clawdsl.nim:1319-1343`
- SuperAdmin invite issuance precedent: `src/claw/agent/binding.nim:73` (only-when-unbound semantics)
- `saveWorld`: `src/claw/agent/cortex.nim:583`
