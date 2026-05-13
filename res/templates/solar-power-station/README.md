# solar-power-station — claw.nim L1 template

A domain template for companies operating a fleet of solar power
stations. Ships with claw.nim. Vendor-neutral but business-opinionated.

## What this template provides

- **2 agents** out of the box: a customer-facing frontdesk + a
  back-office analyst, with a delegate flow wiring them together.
- **5 competencies** practiced by the agents: `solar-operator`,
  `solar-frontdesk`, `data-analyst`, `technical-communication`,
  `knowledge-keeper`.
- **4 vendor-neutral skills** for fleet operations:
  `daily-yield-sync`, `monthly-report`, `customer-onboarding`,
  `alarm-response`.
- **A solar-adapter facade** that abstracts vendor differences —
  skills call the `solar` tool; the adapter routes to the right
  vendor MCP server per plant.
- **A vendor contract** (`vendor/CONTRACT.md`) documenting how to
  add a new inverter brand. Ships with a `_template/` skeleton and
  `sungrow/` as the first complete implementation.

## What this template does NOT commit to

- A specific inverter brand. The solar adapter routes to whatever
  vendor MCP servers are installed (SunGrow, Huawei, GoodWe, …).
  Multi-vendor fleets are first-class.
- Specific customer entities. Each deployment adds its own.
- Specific channel credentials. The deployment configures these in
  `.env` after `claw co create`.
- A delivery channel. The template works with any channel claw
  supports (Feishu, Telegram, Discord, nMobile, etc.).

## Quick start

```bash
claw co create my-solar-co --template solar-power-station
cd ~/.nimclaw-my-solar-co
# Edit .env with your vendor API credentials (see vendor/<name>/README.md)
# Edit BASE.nims to set agent personas, channels, etc.
claw co update
claw gateway
```

## Multi-vendor fleets

A fleet operator with SunGrow at sites A+B and Huawei at sites C+D
installs both vendors:

```nims
# BASE.nims
skill "sungrow"   # equipment vendor at vendor/equipment/sungrow/
skill "huawei"    # equipment vendor at vendor/equipment/huawei/
```

The solar adapter discovers plants from both APIs at startup,
populates the cortex graph with `plant → vendor` mapping, and routes
each per-plant query to the right vendor automatically. Skills like
`daily-yield-sync` work unchanged across vendor mixes.

## Adding a new vendor

See `vendor/CONTRACT.md`. Copy `vendor/_template/` to
`vendor/<your-vendor>/`, implement the five required tools per the
schemas, and `skill "vendor/<your-vendor>"` to opt in.

## Architecture references

- L0/L1/L2 tiering: see the `tools` foundation skill in
  `res/foundation/tools/SKILL.md`
- Skill, competency, heart concepts: same
- Why this is a domain template (not a capability pattern):
  domain templates capture the BUSINESS shape (frontdesk + analyst +
  reporting + alarm response) which a capability pattern can't.
