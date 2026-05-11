# vendor/_template — Skeleton

Starting point for a new inverter-vendor adapter.

## Quick start

```bash
cp -r vendor/_template vendor/<your-vendor>
cd vendor/<your-vendor>
# Rename `vendor-template` → `<your-vendor>` in:
#   - src/stub.nim (the VendorName constant)
#   - SKILL.md frontmatter (name + description)
#   - this README
# Implement real API calls in src/<your-vendor>.nim
# Document env vars below
# In your deployment's BASE.nims:
#   skill "vendor/<your-vendor>"
```

## Files

- `SKILL.md` — claw skill manifest with frontmatter
- `src/stub.nim` — MCP server source. Implements the 5 required
  tools per `../CONTRACT.md` with hardcoded mock data
- `README.md` — this file. Replace with your vendor-specific
  setup notes once you've forked

## Required env vars

The skeleton doesn't need any. Your real implementation will.
Document them here using `<VENDOR_UPPER>_` prefix:

```
MYVENDOR_APIKEY            # primary credential
MYVENDOR_USER_ACCOUNT      # if OAuth-style
MYVENDOR_USER_PASSWORD     # if OAuth-style
MYVENDOR_REGION            # if regional endpoints
MYVENDOR_BASE_URL          # if not hardcoded
```

## Validation

After installing your vendor in a deployment, verify the contract
holds:

```bash
claw gateway --debug 2>&1 | grep "vendor.*$VENDOR"
```

Should see:
```
[INFO] fleet_adapter: vendor `<your-vendor>` registered, contract v1 OK
```

If you see warnings about schema drift, the named field is the one
to fix in your implementation.

## Build

```bash
nim c -d:ssl -d:release --threads:on --mm:orc \
  -o:$NIMCLAW_DIR/workspace/skills/vendor-<your-vendor>/bin/<your-vendor> \
  vendor/<your-vendor>/src/<your-vendor>.nim
```

The framework's `claw skill install` handles this automatically when
the skill is added to BASE.nims, but the command above is useful for
local iteration.
