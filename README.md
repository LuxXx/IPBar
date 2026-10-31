# IPBar

A tiny macOS menu bar app that shows your public IP with its country flag, powered by [ipinfo.io](https://ipinfo.io).

```
🇩🇪 203.0.113.42
```

## Features

- **Menu bar**: flag + IP (or flag only, IP only, country code + IP, flag + country code)
- **Popover**: IP, hostname, ISP, ASN, country, region, city, postal code, time zone, coordinates, Wi-Fi network, VPN state and a map. Click any value to copy it.
- **Auto refresh**: every 5 minutes, on network changes (Wi-Fi switch, VPN up/down) and after wake
- **Notifications** when your IP or country changes
- **History log** for later analysis (see below)
- Optional ipinfo.io token, launch at login

## Build

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools).

```sh
./build.sh            # builds IPBar.app in this folder
./build.sh --install  # also copies it to /Applications and launches it
```

The app is ad-hoc signed for local use.

## Log

Lookups are appended to `~/Library/Application Support/IPBar/ip-log.jsonl` (the folder can be moved, e.g. to iCloud Drive, in Settings). One JSON object per line, written whenever the IP, Wi-Fi network or VPN state changes, and otherwise at most once per hour:

```json
{"city":"Berlin","country":"DE","interface":"en0","ip":"203.0.113.42","loc":"52.5200,13.4050","network_type":"wifi","org":"AS64500 Example ISP","region":"Berlin","ssid":"MyWiFi","timestamp":"2026-10-31T06:29:36Z","timezone":"Europe/Berlin","trigger":"change","vpn":false}
```

| Field | Source | Meaning |
|---|---|---|
| `ip`, `city`, `region`, `country`, `loc`, `org`, `timezone`, `hostname`, `postal` | ipinfo.io | as returned |
| `ssid` | local | Wi-Fi name (requires Location Services permission) |
| `network_type` | local | `wifi`, `hotspot`, `ethernet`, `cellular`, `other` |
| `interface` | local | physical interface, e.g. `en0` |
| `vpn`, `vpn_interface` | local | whether internet traffic leaves through a tunnel interface |
| `timestamp` | local | ISO 8601, UTC |
| `trigger` | local | `change`, or why an unchanged entry was written (`timer`, `launch`, `network`, `wake`, `open`, `manual`) |

Load it with pandas (`pd.read_json(path, lines=True)`) or DuckDB (`SELECT * FROM read_json('ip-log.jsonl')`).
