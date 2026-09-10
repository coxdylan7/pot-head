# Pot Head

Top-bar dispensary finder for Omarchy. Shows the **closest NY licensed dispensary** in your top bar (via NYS Open Data + GPS) — name only, as you requested — and on click reveals the **next 5 closest** with **store hours (today), distance, ETA**, plus **Navigate** and **Visit Site**.

![preview](preview.png)

## Features

- **Top-bar only, name only** — `🌿 Valley Greens Ltd.` in your bar (right section, `djc.pot-head`). No distance clutter.
- **Click → next 5** — popup lists the next 5 closest dispensaries (so 6 total incl. bar) sorted by Haversine distance.
- **Per-row:** `Name • Address • 0.7 mi • 2 min • Hours today • Open/Closed badge • [Navigate] [Site]` — hours parsed for today via `PotHead.js:parseHoursForToday()`.
- **Navigate:** `xdg-open https://www.google.com/maps/dir/?api=1&destination=lat,lon` (tap row also navigates).
- **Visit Site:** `xdg-open <business_website>` (hidden when empty).
- **NYS Open Data:** `data.ny.gov` Socrata `jskf-tt3q` (OCM Licenses, filtered `Active` retail) joined to `gttd-5u6y` (georeference `Point`) for lat/lon — single `?$limit=5000` fetch, join on `license_number = ocm_license_number`, cached to `~/.cache/omarchy/pot-head/dispensaries.json` (refresh `updateMinutes:360`).
- **GPS:** `Geoclue2` via `gdbus` → fallback `ipinfo.io/json` → `locationOverrideLat/Lon` in `shell.json` for testing (Times Square `40.7580,-73.9855` in example). `locationPollSeconds:300`.
- **Distance/ETA:** Haversine `mi`/`km` + `distance / 25 mph` ETA.

## Requirements

- Omarchy (Quickshell shell) — `bar-widget` + `service`, `keepLoaded:true`
- `curl` (for `data.ny.gov`), `python3` (join), `xdg-open`
- `Geoclue2` (optional, for accurate GPS) or IP fallback
- No `app_token` needed (public); add `appToken` in config for higher rate limit.

## Installation

```sh
omarchy plugin add https://github.com/coxdylan7/pot-head --enable
# or manual:
mkdir -p ~/.config/omarchy/plugins
cp -r djc.pot-head ~/.config/omarchy/plugins/
omarchy restart shell
```

Then add to `~/.config/omarchy/shell.json`:

```json
{
  "bar": {
    "layout": {
      "right": [{ "id": "djc.pot-head" }, { "id": "omarchy.tray" }]
    }
  },
  "plugins": [
    {
      "id": "djc.pot-head",
      "locationOverrideLat": "40.7580",
      "locationOverrideLon": "-73.9855",
      "units": "mi"
    }
  ]
}
```

Full config (all optional):

```json
{
  "id": "djc.pot-head",
  "apiUrl": "https://data.ny.gov/resource/jskf-tt3q.json",
  "geoApiUrl": "https://data.ny.gov/resource/gttd-5u6y.json",
  "appToken": "",
  "updateMinutes": 360,
  "locationPollSeconds": 300,
  "maxResults": 6,
  "units": "mi",
  "locationOverrideLat": "",
  "locationOverrideLon": ""
}
```

| Key | Default | Description |
| --- | --- | --- |
| `apiUrl` | `jskf-tt3q` | OCM licenses Socrata endpoint |
| `geoApiUrl` | `gttd-5u6y` | Georeference endpoint |
| `appToken` | `""` | Socrata `X-App-Token` |
| `updateMinutes` | `360` | Dispensary refresh |
| `locationPollSeconds` | `300` | GPS poll |
| `maxResults` | `6` | Closest + next 5 |
| `units` | `mi` | `mi` or `km` |
| `locationOverrideLat/Lon` | `""` | Test location |

## Development

```sh
omarchy plugin validate ~/.config/omarchy/plugins/djc.pot-head
omarchy restart shell
```

## License

MIT — see [LICENSE](LICENSE).
