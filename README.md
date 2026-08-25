# OmaCoin

An [Omarchy](https://omarchy.org/) shell plugin that tracks crypto prices via
the [CoinGecko](https://www.coingecko.com/) public API.

## What you get

- **Bar widget**: the primary coin's symbol, USD price, and 24h change.
  Left click opens the detail popup, middle click cycles the primary through
  your tracked coins, right click forces a refresh.
- **Detail popup**:
  - Primary-coin hero with USD price and 24h volume
  - Trend line with **1 hour / 1 day / 1 week** ranges
  - Tracked-coin list: USD price, volume, and 1h/24h/7d change for each coin
  - Click a coin (or its ★) to make it the primary shown in the bar
  - ✕ removes a coin from the list
  - CoinGecko search to add any coin by name or symbol
  - Check-frequency picker

## Check frequency

CoinGecko's public API accepts roughly one call per minute from an IP (and
refreshes its cache every 30–60s), so the ladder runs from that minimum up to
once per day: **1, 2, 5, 10, 15, 30, 60, 120, 240, 360, 720 minutes, 1 day**.
Default: **once per hour**. Each check is a single `/coins/markets` call that
covers every tracked coin, so tracking more coins costs no extra calls.

## State

Everything lives inline on the widget's entry in `~/.config/omarchy/shell.json`:

- `coins` — tracked CoinGecko ids (default: `["bitcoin", "ethereum"]`)
- `primary` — coin shown in the bar (default: `"bitcoin"`)
- `intervalMin` — check frequency in minutes (default: `60`)

All of it is editable from the popup, so you never have to touch the file.

## Install

```bash
omarchy plugin add https://git.packden.us/crueber/omarchy-plugin-omacoin.git --enable --yes
```

or by hand:

```bash
git clone https://git.packden.us/crueber/omarchy-plugin-omacoin.git \
  ~/.config/omarchy/plugins/crueber.omacoin
omarchy-shell shell rescanPlugins
omarchy plugin enable crueber.omacoin
```

Requires `curl` (used for all CoinGecko requests).

## License

MIT
