## sungrow.nim — STUB implementation of the SunGrow iSolarCloud vendor.
##
## Conforms to res/templates/solar-power-station/vendor/CONTRACT.md.
## Returns hardcoded SunGrow-flavored mock data — useful for verifying
## the fleet adapter's routing without real iSolarCloud credentials.
##
## To wire real API access, replace this file with the production
## SunGrow implementation. See ../README.md for guidance.

import std/[json, times, strutils, options]

const VendorName = "sungrow"
const PlantIdPrefix = "SG-"

# Mock fleet — three plants spanning the typical operational shape
# of a small fleet operator (mid-size station + 2 smaller stations).
const mockPlants = [
  (id: "SG-12345", psId: "12345", name: "无锡中亚",
   capacityKwp: 815.35, installDate: "2023-06-15",
   lat: 31.491, lng: 120.312, tz: "Asia/Shanghai",
   region: "cn", mlpe: true),
  (id: "SG-12346", psId: "12346", name: "荣鑫二期",
   capacityKwp: 400.0, installDate: "2024-03-22",
   lat: 31.5, lng: 120.4, tz: "Asia/Shanghai",
   region: "cn", mlpe: false),
  (id: "SG-12347", psId: "12347", name: "荣鑫一期",
   capacityKwp: 396.0, installDate: "2023-09-01",
   lat: 31.48, lng: 120.38, tz: "Asia/Shanghai",
   region: "cn", mlpe: false),
]

proc findPlant(plantId: string): Option[tuple] =
  for p in mockPlants:
    if p.id == plantId: return some(p)
  none(tuple)

proc plantJson(p: auto): JsonNode =
  ## Plant per schemas/plant.json + vendor extensions.
  %*{
    "id": p.id,
    "vendor": VendorName,
    "name": p.name,
    "capacity_kwp": p.capacityKwp,
    "install_date": p.installDate,
    "location": {
      "latitude": p.lat,
      "longitude": p.lng,
      "address": "",
      "timezone": p.tz
    },
    "status": "online",
    "sungrow_ps_id": p.psId,
    "sungrow_region": p.region,
    "sungrow_mlpe_enabled": p.mlpe
  }

# ── Mock yield model ─────────────────────────────────────────────
# Returns plausible per-day yield: roughly capacity_kwp * 5 hours
# (typical equivalent-hours for mid-latitude sites), with a
# deterministic ±10% variation by date so the data isn't flat.

proc dateSeed(dateStr: string): float =
  ## Deterministic 0..1 value from a date string. Lets the stub
  ## return varying-but-reproducible yields without an RNG.
  var s: int = 0
  for c in dateStr:
    s = (s * 31 + ord(c)) mod 9973
  result = s.float / 9973.0

proc mockYield(capacityKwp: float, dateStr: string): float =
  ## ~5 equivalent-hours × capacity, with ±10% variation seeded
  ## by the date.
  let factor = 4.5 + dateSeed(dateStr) * 1.0  # 4.5–5.5 EH
  result = capacityKwp * factor

# ── MCP server ────────────────────────────────────────────────────

mcpServer(VendorName):

  # ── Contract tool 1: plant_list ─────────────────────────────────
  mcpTool:
    proc plant_list(): JsonNode =
      ## Required contract tool. Returns all plants in this vendor's
      ## fleet as an array of Plant objects (per schemas/plant.json).
      var arr = newJArray()
      for p in mockPlants:
        arr.add(plantJson(p))
      result = arr

  # ── Contract tool 2: plant_now ──────────────────────────────────
  mcpTool:
    proc plant_now(plant_id: string): JsonNode =
      ## Required contract tool. Returns real-time state for one
      ## plant (per schemas/plant_now.json).
      let plant = findPlant(plant_id)
      if plant.isNone:
        return %*{"error": "plant_not_found", "plant_id": plant_id}
      let p = plant.get
      let today = now().utc.format("yyyy-MM-dd")
      let todayKwh = mockYield(p.capacityKwp, today)
      # Mock current_kw: 0 at "night" (alternating by date seed),
      # ~30-40% of capacity otherwise to keep responses lively
      let inDaylight = dateSeed(today) > 0.3
      let currentKw = if inDaylight: p.capacityKwp * 0.35 else: 0.0
      result = %*{
        "plant_id": p.id,
        "vendor": VendorName,
        "current_kw": currentKw,
        "today_kwh": todayKwh,
        "status": "online",
        "alarms_count": 0,
        "timestamp": $now().utc,
        "capacity_kwp": p.capacityKwp,
        "sungrow_ps_id": p.psId
      }

  # ── Contract tool 3: plant_history ──────────────────────────────
  mcpTool:
    proc plant_history(plant_id: string,
                        `from`: string,
                        `to`: string): JsonNode =
      ## Required contract tool. Returns daily yield over the date
      ## range as an array of YieldPoint (per schemas/yield_point.json).
      ## NOTE: `from` and `to` are reserved Nim words — quote with
      ## backticks; the MCP wire spec exposes them as `from`/`to`.
      let plant = findPlant(plant_id)
      if plant.isNone:
        return %*{"error": "plant_not_found", "plant_id": plant_id}
      let p = plant.get
      var arr = newJArray()
      try:
        let startDt = parse(`from`, "yyyy-MM-dd").utc
        let endDt = parse(`to`, "yyyy-MM-dd").utc
        var cur = startDt
        while cur <= endDt:
          let dateStr = cur.format("yyyy-MM-dd")
          let kwh = mockYield(p.capacityKwp, dateStr)
          let isToday = (dateStr == now().utc.format("yyyy-MM-dd"))
          arr.add(%*{
            "plant_id": p.id,
            "vendor": VendorName,
            "date": dateStr,
            "yield_kwh": kwh,
            "peak_kw": p.capacityKwp * 0.75,  # mock peak ≈ 75% of capacity
            "equivalent_hours": kwh / p.capacityKwp,
            "data_quality": if isToday: "provisional" else: "final"
          })
          cur = cur + 1.days
      except CatchableError as e:
        return %*{"error": "bad_date_range", "message": e.msg}
      result = arr

  # ── Contract tool 4: inverter_list ──────────────────────────────
  mcpTool:
    proc inverter_list(plant_id: string): JsonNode =
      ## Required contract tool. Returns inverters under one plant.
      ## Schema TBD (vendor/schemas/inverter.json not yet defined);
      ## the stub returns a sensible shape that production
      ## implementations should match.
      let plant = findPlant(plant_id)
      if plant.isNone: return %*[]
      let p = plant.get
      # Mock: ~2 inverters per plant, sized to total the plant capacity.
      let invCap = p.capacityKwp / 2.0
      result = %*[
        {
          "id": p.id & "-INV-1",
          "plant_id": p.id,
          "vendor": VendorName,
          "model": "SG110CX",
          "capacity_kw": invCap,
          "status": "online",
          "sungrow_device_type": 1
        },
        {
          "id": p.id & "-INV-2",
          "plant_id": p.id,
          "vendor": VendorName,
          "model": "SG110CX",
          "capacity_kw": invCap,
          "status": "online",
          "sungrow_device_type": 1
        }
      ]

  # ── Contract tool 5: inverter_alarms ────────────────────────────
  mcpTool:
    proc inverter_alarms(plant_id: string): JsonNode =
      ## Required contract tool. Active alarms on inverters under
      ## one plant. Stub returns empty (no alarms) for all plants —
      ## production implementations return real alarm data.
      let plant = findPlant(plant_id)
      if plant.isNone: return %*[]
      result = %*[]
