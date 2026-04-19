# ClawDSL Schema

The declarative vocabulary used in `BASE.nims` and its generated graph.
Small on purpose — schema.org's common shapes filtered to the handful
of concepts a multi-agent company actually needs.

## The four axes

Every fact the graph records belongs to exactly one of these:

| Axis | Question | Example |
|---|---|---|
| **Entity kind** | *What is it?* | Person \| Agent \| Company |
| **Identity**    | *Who is it?* | `nc:4` "Alice", jobTitle "Designer", locale "zh-CN", feishu:<id> |
| **Permission**  | *How do I treat it?* | SuperAdmin / Admin / Staff / Boss / Customer / Guest |
| **Relationship**| *How is it connected to others?* | Lexi `reportsTo` Jerry (trust 100) |

Nothing belongs in two axes. If a concept feels like it's straddling
two, it's probably misnamed.

---

## Axis 1 — Entity Kind

The *type* of thing. The DSL keyword used to declare an entity names
its kind:

```nim
person "Jerry":   ...   # kind = Person   (human)
agent  "Lexi":    ...   # kind = Agent    (AI; LLM-backed)
company "Acme":   ...   # kind = Company  (organisation)
```

Three values cover our world today. Future kinds (`Service`, `Bot`,
`Device`) would go here if we added them — but deliberately flat, no
sub-taxonomies.

---

## Axis 2 — Identity

Describes *who* this entity is. Stable, descriptive, carries no
authority on its own.

```
Identity = {
  nc:id           stable machine key (e.g. "nc:4")
  displayName     short human name — "Jerry", "Alice", "Lexi"
  attributes {}   open key-value metadata — jobTitle, locale,
                  pronouns, bio, timezone, anything a skill wants
  identifiers []  per-channel addresses — feishu:<app>:<open_id>,
                  nkn:<address>, telegram:<user_id>, …
}
```

`nc:id` is written once when the entity is minted and never changes.
Everything else can be edited — `user register` / `user merge` / DSL
updates all flow through the identity layer.

### DSL

Two interchangeable forms for attributes:

```nim
# Shortcut: inline kwargs (2-3 common attributes)
agent "Lexi", jobTitle = "Solar Ops Analyst", locale = "zh-CN":
  permission "Staff"

# Canonical: block (extensible, any keys, labelled)
agent "Lexi":
  attributes:
    jobTitle "Solar Ops Analyst"
    pronouns "she/they"
    locale "zh-CN"
    bio "Ten years in solar ops."
    timezone "Asia/Shanghai"
  permission "Staff"
```

Both land in the same `WorldEntity.custom: JsonNode` bag at storage
time. Third-party skills add keys without touching the DSL spec.

`identifier "<channel>", "<senderID>"` adds to the channel-address list:

```nim
person "Alice":
  identifier "feishu:cli_a93085...", "ou_b785f57..."
  identifier "feishu:cli_a931b7...", "ou_a2b306c..."
```

---

## Axis 3 — Permission

*How* to treat this identity. Six values, three tiers. Trust level
(0-100) overlays on top for finer control.

| Tier     | Value         | Who                                              |
|----------|---------------|--------------------------------------------------|
| Internal | `SuperAdmin`  | Owns the company. One per company, typically.    |
| Internal | `Admin`       | Manages most of the company. May delegate.       |
| Internal | `Staff`       | Regular employee/agent. Trusted, scoped.         |
| External | `Boss`        | VIP from a partner/customer org.                 |
| External | `Customer`    | Known, verified external contact.                |
| Unknown  | `Guest`       | First-contact, untrusted default.                |

### DSL

```nim
person "Jerry":
  permission "SuperAdmin"

person "Alice":
  permission "Customer"

agent "Lexi":
  permission "Staff"
```

Permission replaces the legacy three-word soup (`role`, `identity`,
`permission-group`). Whatever was `role "Admin"` / `identity "Staff"` /
`permission "SuperAdmin"` in the old DSL collapses to a single
`permission "..."`.

### Trust bands

Per-company policy (optional). Declared in the `trust:` block, maps
each permission value to a trust range + default + grants:

```nim
trust:
  role "SuperAdmin":
    band 90, 100
    initial 100
    grant "*"
    prompt "🛡️ HIGH TRUST — execute without hesitation."
  role "Customer":
    band 30, 60
    initial 40
    grant "reply", "forward", "update_contact"
  role "Guest":
    band 0, 40
    initial 10
    grant "reply", "forward", "redeem_invite"
    prompt "⚠️ GUEST — public info only."
```

(The `trust` DSL already uses `role` as the keyword; read as *permission
band*. Bands can be renamed to `permission` too if we want perfect
alignment — deferred.)

---

## Axis 4 — Relationship

Typed, directional edge between two identities. Each edge carries its
own annotation (trust, etiquette, maybe jobTitle-at-this-employer).

### Vocabulary

| Relationship | Meaning                                   | Example                                     |
|---|---|---|
| `reportsTo`  | A reports up to B                          | Lexi reportsTo Jerry                        |
| `master`     | Stronger reportsTo — commander/mentor      | Student master "Yoda"                       |
| `manages`    | Inverse of reportsTo                       | Jerry manages Lexi                          |
| `serves`     | A provides services to B                   | Lexi serves Alice                           |
| `employs`    | Company A employs Person B                 | SunGrowCN employs Jerry                     |
| `memberOf`   | A is part of group B                       | Lexi memberOf ops-team                      |
| `colleague`  | Peer within the same org                   | Lexi colleague Atlas                        |
| `student`    | A receives teaching from B                 | (mirror of master)                          |
| `friend`     | Peer, not org-scoped                       | Jerry friend Bob                            |

Not an enum — the DSL accepts any relationship keyword and stores the
type verbatim on the edge. The runtime doesn't interpret unknown types;
it just shows them in `user list`. Operators can add their own
(`partnerWith`, `mentees`) without changing the binary.

### DSL

Each relationship is its own sub-block on the source entity:

```nim
agent "Lexi":
  permission "Staff"
  reportsTo "Jerry":
    trustLevel 100
    etiquette "Concise. Numbers-first."
  colleague "Atlas":
    trustLevel 70
  serves "Alice":
    trustLevel 50
```

### Edge annotation fields

Each edge carries:

| Field | Required | Notes |
|---|---|---|
| `trustLevel`   | optional | 0-100. Ignored when the opposite side's permission is enough on its own. |
| `etiquette`    | optional | Free-form tone/style hint injected into the system prompt. |
| `jobTitle`     | optional | When relationship is `employs`/`memberOf`/`worksFor`: titling scoped to this employer. |

---

## Full DSL example (target)

```nim
import claw/clawdsl

org "SunGrowCN":
  description "Solar + storage fleet monitoring."

company "SunGrowCN":
  # (optional) Company as an entity in its own right for memberOf/employs.

person "Jerry":
  permission "SuperAdmin"
  attributes:
    jobTitle "CEO"
    pronouns "he/him"

person "Alice":
  permission "Customer"
  identifier "feishu:cli_a93085...", "ou_b785f570..."
  identifier "feishu:cli_a931b7...", "ou_a2b306c9..."

agent "Lexi", jobTitle = "Solar Ops Analyst", locale = "zh-CN":
  permission "Staff"
  reportsTo "Jerry":
    trustLevel 100
    etiquette "Concise. Numbers-first."
  serves "Alice":
    trustLevel 50
  memberOf "SunGrowCN":
    jobTitle "Solar Ops Analyst"
```

---

## Storage layer mapping

| DSL field              | WorldEntity field            | JSON key                    |
|---|---|---|
| entity kind            | `kind: EntityKind`           | `kind`                      |
| displayName            | `name: string`               | `name`                      |
| permission             | `permission: string`         | `permission`                |
| attributes block       | `custom: JsonNode` (object)  | `attributes` (or top-level for compat) |
| identifiers            | `identifiers: Table[..]`     | `identifiers`               |
| relationship edges     | `reportsTo/serves` per type  | `reportsTo[]`, `serves[]`, per-type arrays |
| edge.trustLevel        | `RelationshipAnnotation`     | `@annotation.trustLevel`    |
| edge.etiquette         | `RelationshipAnnotation`     | `@annotation.etiquette`     |
| edge.jobTitle          | `RelationshipAnnotation`     | `@annotation.jobTitle`      |

---

## Migration from the legacy DSL

| Old                           | New                                             |
|---|---|
| `role "Admin"` on agent       | `permission "Admin"`                            |
| `identity "Staff"` on agent   | (fold into `permission`; drop separate axis)    |
| `permission "SuperAdmin"` on person | `permission "SuperAdmin"` (unchanged)      |
| `jobTitle "..."` on agent     | `jobTitle = "..."` in kwargs or `attributes:`   |
| `reportsTo "X": role "boss"`  | `reportsTo "X":` (the relationship TYPE is the keyword; drop the stray `role`) |
| `UserRole = enum { urBoss, urMaster, … }` | Deleted. Runtime gates on `permission` string instead. |

A `claw co migrate` command rewrites existing BASE.nims files in place,
emitting the new shape and warning on ambiguous cases.

---

## Non-goals

- **Not** a full ontology framework. Seven relationship types, six
  permission values, three entity kinds — if you need more, add them,
  but resist the urge to subclass.
- **Not** RDF. We're not generating triples; we're describing a graph
  a company's agents reason over. JSON-LD keywords happen to help with
  interop but we don't aim for semantic-web conformance.
- **Not** multi-tenant. One claw instance = one company. Entities are
  scoped to the instance; cross-instance federation is a different
  problem (NKN/nMobile address space).
