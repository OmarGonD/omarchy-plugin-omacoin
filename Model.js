.pragma library

// Pure helpers for OmaCoin: settings normalization, CoinGecko response
// parsing, and formatting. No Qt imports — everything here is plain JS so
// it can be shared by the bar widget and the panel.

// ---------------------------------------------------------------- settings

// CoinGecko's public API allows roughly 10-30 calls/minute from an IP and
// refreshes its price cache every 30-60s, so one call per minute is the
// fastest check frequency it meaningfully accepts. The ladder runs from
// that minimum up to once per day; the default is once per hour.
var INTERVAL_LADDER = [1, 2, 5, 10, 15, 30, 60, 120, 240, 360, 720, 1440]

function intervalOptions() {
  var options = []
  for (var i = 0; i < INTERVAL_LADDER.length; i++) {
    options.push({ value: String(INTERVAL_LADDER[i]), label: intervalLabel(INTERVAL_LADDER[i]) })
  }
  return options
}

function intervalLabel(minutes) {
  var m = Number(minutes)
  if (!isFinite(m) || m < 60) return m + (m === 1 ? " minute" : " minutes")
  if (m < 1440) {
    var h = m / 60
    var hs = (h === Math.floor(h) ? String(h) : h.toFixed(1))
    return hs + (h === 1 ? " hour" : " hours")
  }
  return "1 day"
}

// Snap any hand-edited value onto the ladder (nearest rung).
function clampInterval(value) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return 60
  var best = INTERVAL_LADDER[0]
  for (var i = 1; i < INTERVAL_LADDER.length; i++) {
    if (Math.abs(INTERVAL_LADDER[i] - n) < Math.abs(best - n)) best = INTERVAL_LADDER[i]
  }
  return best
}

// Normalize a coins setting (array, or comma-separated string from a
// hand-edited shell.json) into a deduplicated lowercase id array.
function coinList(value) {
  var raw = []
  if (Array.isArray(value)) raw = value.slice()
  else if (typeof value === "string") raw = value.split(",")
  var seen = {}
  var out = []
  for (var i = 0; i < raw.length; i++) {
    var id = String(raw[i] || "").replace(/^\s+|\s+$/g, "").toLowerCase()
    if (id === "" || seen[id]) continue
    seen[id] = true
    out.push(id)
  }
  return out
}

// The primary must be one of the tracked coins; fall back to the first.
function primaryId(coins, primarySetting) {
  var list = coinList(coins)
  var wanted = String(primarySetting || "").toLowerCase()
  for (var i = 0; i < list.length; i++) if (list[i] === wanted) return list[i]
  return list.length > 0 ? list[0] : ""
}

// ---------------------------------------------------------------- parsing

function parseJson(raw) {
  var text = String(raw || "").replace(/^\s+|\s+$/g, "")
  if (text === "") return null
  try { return JSON.parse(text) } catch (e) { return null }
}

function num(value) {
  var n = Number(value)
  return isFinite(n) ? n : null
}

// /api/v3/coins/markets?vs_currency=usd&ids=...&sparkline=true
// &price_change_percentage=1h,24h,7d  →  map keyed by coin id.
function parseMarkets(raw) {
  var data = parseJson(raw)
  if (!Array.isArray(data)) return null
  var map = {}
  for (var i = 0; i < data.length; i++) {
    var r = data[i]
    if (!r || !r.id) continue
    map[String(r.id)] = {
      id: String(r.id),
      symbol: String(r.symbol || r.id).toUpperCase(),
      name: String(r.name || r.id),
      price: num(r.current_price),
      vol24h: num(r.total_volume),
      high24h: num(r.high_24h),
      low24h: num(r.low_24h),
      change1h: num(r.price_change_percentage_1h_in_currency),
      change24h: num(r.price_change_percentage_24h_in_currency !== undefined
        ? r.price_change_percentage_24h_in_currency : r.price_change_percentage_24h),
      change7d: num(r.price_change_percentage_7d_in_currency),
      spark7d: (r.sparkline_in_7d && Array.isArray(r.sparkline_in_7d.price)) ? r.sparkline_in_7d.price : []
    }
  }
  return map
}

// Order the parsed markets map along the tracked-coin list; unknown ids
// (delisted / typo) are kept out — the add flow re-resolves them by search.
function orderRows(map, coins) {
  var out = []
  var list = coinList(coins)
  for (var i = 0; i < list.length; i++) if (map && map[list[i]]) out.push(map[list[i]])
  return out
}

function rowById(rows, id) {
  var wanted = String(id || "")
  for (var i = 0; i < rows.length; i++) if (rows[i].id === wanted) return rows[i]
  return null
}

// /api/v3/search?query=...  →  [{id, name, symbol, rank}]
function parseSearch(raw) {
  var data = parseJson(raw)
  if (!data || !Array.isArray(data.coins)) return []
  var out = []
  for (var i = 0; i < data.coins.length; i++) {
    var c = data.coins[i]
    if (!c || !c.id) continue
    out.push({
      id: String(c.id),
      name: String(c.name || c.id),
      symbol: String(c.symbol || "").toUpperCase(),
      rank: num(c.market_cap_rank)
    })
  }
  return out
}

// /api/v3/coins/{id}/market_chart?vs_currency=usd&days=1  →  [[ts, price]...]
function parseMarketChart(raw) {
  var data = parseJson(raw)
  if (!data || !Array.isArray(data.prices)) return []
  var out = []
  for (var i = 0; i < data.prices.length; i++) {
    var p = data.prices[i]
    if (!Array.isArray(p) || p.length < 2) continue
    var price = num(p[1])
    var ts = num(p[0])
    if (price === null || ts === null) continue
    out.push([ts, price])
  }
  return out
}

// Slice a [[ts, price]] series down to its last `minutes` (5-minutely data
// from days=1, so an hour is ~12 points).
function windowPoints(series, minutes) {
  if (!Array.isArray(series) || series.length === 0) return []
  var last = series[series.length - 1][0]
  var cutoff = last - minutes * 60 * 1000
  var out = []
  for (var i = 0; i < series.length; i++) {
    if (series[i][0] >= cutoff) out.push(series[i][1])
  }
  return out.length >= 2 ? out : series.map(function(p) { return p[1] })
}

function seriesChange(prices) {
  if (!Array.isArray(prices) || prices.length < 2) return null
  var first = Number(prices[0])
  var last = Number(prices[prices.length - 1])
  if (!isFinite(first) || !isFinite(last) || first === 0) return null
  return (last - first) / first * 100
}

// ------------------------------------------------------------- formatting

function group(intPart) {
  var negative = intPart.indexOf("-") === 0
  var digits = negative ? intPart.slice(1) : intPart
  var out = ""
  while (digits.length > 3) {
    out = "," + digits.slice(-3) + out
    digits = digits.slice(0, -3)
  }
  return (negative ? "-" : "") + digits + out
}

function formatUsd(value) {
  if (value === null || value === undefined) return "—"
  var n = Number(value)
  if (!isFinite(n) || n < 0) return "—"
  if (n >= 1000) return "$" + group(String(Math.round(n)))
  if (n >= 1) return "$" + group(String(Math.floor(n))) + "." + decimals(n, 2)
  if (n >= 0.01) return "$0." + decimals(n, 4)
  if (n === 0) return "$0.00"
  var sig = n.toPrecision(4).replace(/0+$/, "").replace(/\.$/, "")
  return "$" + (sig.indexOf(".") < 0 ? sig + ".00" : sig)
}

function decimals(n, places) {
  var s = n.toFixed(places)
  var dot = s.indexOf(".")
  return dot < 0 ? "00" : s.slice(dot + 1)
}

function formatCompactUsd(value) {
  var n = Number(value)
  if (!isFinite(n) || n <= 0) return "—"
  if (n >= 1e12) return "$" + (n / 1e12).toFixed(1) + "T"
  if (n >= 1e9) return "$" + (n / 1e9).toFixed(1) + "B"
  if (n >= 1e3) return "$" + (n / 1e3).toFixed(1) + "K"
  return "$" + Math.round(n)
}
function formatPct(value) {
  if (value === null || value === undefined) return "—"
  var n = Number(value)
  if (!isFinite(n)) return "—"
  return (n > 0 ? "+" : "") + n.toFixed(2) + "%"
}

function formatTime(date) {
  if (!date || typeof date.getTime !== "function" || date.getTime() === 0) return "—"
  var h = date.getHours()
  var m = date.getMinutes()
  return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
}

// ---------------------------------------------------------------- sparkline

// Map a price series onto a w×h canvas with padding. Flat series draw a
// midline rather than a divide-by-zero.
function sparkPoints(series, w, h, pad) {
  if (!Array.isArray(series) || series.length < 2 || w <= 0 || h <= 0) return []
  var min = Infinity, max = -Infinity
  for (var i = 0; i < series.length; i++) {
    var v = Number(series[i])
    if (!isFinite(v)) continue
    if (v < min) min = v
    if (v > max) max = v
  }
  if (!isFinite(min) || !isFinite(max)) return []
  var span = max - min
  var mid = h / 2
  var points = []
  for (var j = 0; j < series.length; j++) {
    var x = pad + (w - pad * 2) * j / (series.length - 1)
    var y = span > 0 ? pad + (h - pad * 2) * (1 - (series[j] - min) / span) : mid
    points.push({ x: x, y: y })
  }
  return points
}
