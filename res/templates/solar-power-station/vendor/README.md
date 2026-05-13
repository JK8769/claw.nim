# Vendor Implementations

This directory hosts inverter-vendor MCP server implementations for
the solar-power-station template's solar adapter.

## Adding a new vendor

1. Read [CONTRACT.md](./CONTRACT.md) — the formal spec.
2. Copy `_template/` to `<your-vendor>/` inside this `vendor/` dir
   (a reference copy — not installed).
3. Author the actual implementation as a skill at
   `workspace/skills/vendor-<your-vendor>/` (with `SKILL.md`,
   `README.md`, `src/<vendor>.nim`).
4. Implement the required tools per the schemas in `schemas/`.
5. Validate output against `examples/*.example.json`.
6. Add `skill "vendor-<your-vendor>"` to your deployment's
   BASE.nims so the resolver installs and compiles it.
7. Set the required env vars (see your vendor's README).

The contract is designed so a coding agent (Claude, Devon, etc.)
can produce a correct adapter from CONTRACT.md + schemas + the
skeleton in one pass.

Why the split: this `vendor/` dir at the template top level holds
the CONTRACT, schemas, examples, and a reference `_template/` for
discoverability. The actual installable vendor MCP servers live
under `workspace/skills/vendor-<name>/` so they integrate with the
standard skill resolver, installer, and binary loader.

## Currently shipped

| Vendor | Skill name | Implementation | Status |
|---|---|---|---|
| `_template` | — (not installed) | reference skeleton | docs only |
| `sungrow` | `vendor-sungrow` | SunGrow iSolarCloud | stub with mock data |
| `huawei` | `vendor-huawei` | Huawei FusionSolar | not yet implemented |
| `goodwe` | `vendor-goodwe` | GoodWe SEMS | not yet implemented |
| `solis` | `vendor-solis` | Solis Cloud | not yet implemented |

## Multi-vendor support

A deployment can install multiple vendors simultaneously. The
solar adapter (`skills/solar-adapter/`) routes per-plant queries
to the right vendor based on the `plant → vendor` mapping in the
cortex graph (populated at first startup from each vendor's
`plant_list`).

Example BASE.nims for a mixed-vendor fleet operator:

```nims
skill "vendor/sungrow"
skill "vendor/huawei"
```

Skills like `daily-yield-sync`, `monthly-report`, `alarm-response`
work unchanged regardless of which combination is installed.

## Contract validation

At gateway boot, the solar adapter:

1. Discovers which `vendor/<name>/` skills are installed
2. Calls each one's `plant_list` (and other floor tools) once
3. Validates the response against `schemas/`
4. Logs warnings for any schema drift, naming the specific field
5. Skips the vendor for the affected operation only — other
   vendors' implementations continue to work

This catches drift early at startup rather than mid-conversation.

## Directory layout

```
vendor/
├── README.md           # this file
├── CONTRACT.md         # formal spec for implementers
├── schemas/            # JSON Schema for each response type
│   ├── plant.json
│   ├── plant_now.json
│   └── yield_point.json
├── examples/           # canonical example outputs per tool
│   ├── plant_list.example.json
│   └── plant_now.example.json
├── _template/          # skeleton vendor implementation
│   ├── SKILL.md
│   └── src/stub.nim
└── <vendor>/           # actual implementations (one dir per vendor)
    ├── SKILL.md
    ├── README.md       # env vars + setup
    └── src/<vendor>.nim
```
