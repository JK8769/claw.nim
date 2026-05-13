# vendor/sungrow — SunGrow iSolarCloud implementation

First reference implementation of the
`res/templates/solar-power-station/vendor/CONTRACT.md` contract.

Read alongside `vendor/CONTRACT.md` for the formal spec and
`vendor/_template/` for the skeleton pattern.

## Required env vars

```
SUNGROW_APPKEY            # iSolarCloud app key
SUNGROW_ACCESS_KEY        # access key from your iSolarCloud
                          # OpenAPI subscription
SUNGROW_USER_ACCOUNT      # account username (the human user, not
                          # the app)
SUNGROW_USER_PASSWORD     # account password
SUNGROW_REGION            # cn | us | eu — picks the regional
                          # endpoint base URL
```

Set these in your deployment's `.env` file BEFORE running
`claw gateway` for the first time. The stub doesn't validate
them; the production implementation logs in once at startup and
caches the auth token.

## Files

- `SKILL.md` — manifest with frontmatter, contract_version
- `README.md` — this file
- `src/sungrow.nim` — MCP server source. Currently a stub
  returning mock data; replace with the production implementation
  to wire real API access

## Status: stub

The shipped `src/sungrow.nim` is a stub for routing verification:

- Compiles standalone (no http client, no auth, no API calls)
- Returns hardcoded SG-prefixed mock plants matching the schemas
- Lets you verify the fleet adapter routes `fleet_*` calls to
  the right vendor without needing real credentials

## Switching to production

The production SunGrow implementation lives in working SunGrow
deployments at:
```
~/.nimclaw-<sungrow-deployment>/workspace/skills/sungrow/src/sungrow.nim
```

It's a ~170KB Nim file covering ~22 tools (the 5 contract + ~17
vendor-specific extensions). To use it:

```bash
# From an existing SunGrow deployment:
cp ~/.nimclaw-<existing>/workspace/skills/sungrow/src/sungrow.nim \
   ~/.nimclaw-<new>/vendor/sungrow/src/sungrow.nim

# Or, when a `sungrow-mcp` community repo is published:
claw skill install --as=vendor/sungrow github:<owner>/sungrow-mcp
```

The production source exposes both:
- The 5 contract tools (`plant_list`, `plant_now`, `plant_history`,
  `inverter_list`, `inverter_alarms`) — used by the fleet adapter
- The 17 vendor-specific tools (`solar_optimizer_now`, etc.) —
  used directly by skills that need SunGrow-only features

The framework's fleet adapter only routes to the 5 contract
tools. Vendor-specific tools remain accessible via their full
`mcp_sungrow_<tool>` name.

## Plant ID convention

All SunGrow plant IDs in this implementation are prefixed `SG-`
followed by the iSolarCloud `ps_id` (e.g. `SG-12345`). The
prefix gives the fleet adapter a fast routing path before the
plant→vendor cache is populated.

## Vendor extension fields

The Plant/PlantNow/Alarm responses include SunGrow-specific
extension fields beyond the contract requirements:

- `sungrow_ps_id` — the underlying numeric ps_id (without the
  `SG-` prefix). Useful for direct API calls if a skill needs
  to reach a vendor-specific endpoint.
- `sungrow_region` — `cn`/`us`/`eu` for regional routing.
- `sungrow_mlpe_enabled` — whether the plant has Module-Level
  Power Electronics (MLPE) optimizers installed (drives
  visibility of `solar_optimizer_*` features).

Vendor-neutral skills (`daily-yield-sync`, `monthly-report`)
ignore these. Vendor-specific skills can read them.

## Testing the stub end-to-end

After `claw co create --template solar-power-station --as=Test`:

```bash
# In deployment:
claw skill install vendor/sungrow   # already declared in BASE.nims
claw co update
claw gateway

# Verify fleet routing works (in another shell):
claw agent send Frontdesk "List my solar plants" --from devon --channel cli
# Expected: response showing 3 mock plants (SG-12345, SG-12346, SG-12347)
```

If you see `[]` instead of plants, the stub's MCP server didn't
register. Check `claw gateway` log for the line `Loading
persistent MCP tool {path=.../bin/sungrow, tier=company, name=sungrow}`.
