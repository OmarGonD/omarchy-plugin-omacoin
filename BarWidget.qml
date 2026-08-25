import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// OmaCoin bar widget: the primary coin's USD price and a direction glyph.
//
// Left click opens the panel (coins tab: tracked list, trends, add/remove;
// settings tab: check frequency and flat-band sliders), middle click cycles
// the primary through the tracked coins, right click forces a refresh. All
// user state lives inline on this widget's shell.json entry (coins /
// primary / intervalMin / flatThresholdPct), written through
// bar.shell.updateEntryInline so every bar instance stays in sync.
//
// Polling: a bar surface exists per monitor, so several instances of this
// widget can be alive at once. Exactly one — the "leader", elected through
// shared library state in Model.js — runs the CoinGecko poll loop and
// publishes results to the others. That keeps the one-call-per-check
// contract regardless of monitor count.
BarWidget {
  id: root
  moduleName: "crueber.omacoin"

  // Normalized /coins/markets rows, ordered along the tracked-coin list.
  // Kept on failure so stale prices stay visible while a retry runs.
  property var marketRows: []

  property date lastUpdated: new Date(0)

  // Fetch health. Empty string when the last check succeeded.
  property string fetchError: ""
  property int fetchRetries: 0
  property bool fetchQueued: false

  // Settings-derived state. QML's dependency tracking does not reliably
  // follow `settings` reads made inside the base class's setting() helper
  // (observed: bindings evaluated once at defaults and never refreshed
  // after the host injects settings), so these are plain properties
  // recomputed by applySettings() instead of bindings.
  property var trackedCoins: ["bitcoin", "ethereum"]
  property string primary: "bitcoin"
  property int intervalMin: 60
  property real flatThresholdPct: Model.FLAT_DEFAULT

  // True while this instance owns the module's single poll loop.
  property bool pollLeader: false

  readonly property var primaryRow: Model.rowById(marketRows, primary)
  readonly property bool hasData: primaryRow !== null

  function applySettings() {
    var coins = Model.coinList(setting("coins", ["bitcoin", "ethereum"]))
    var prim = Model.primaryId(coins, setting("primary", "bitcoin"))
    var iv = Model.clampInterval(setting("intervalMin", 60))
    var flat = Model.clampFlat(setting("flatThresholdPct", Model.FLAT_DEFAULT))
    // Compare before assigning: a fresh array's identity alone would notify
    // onTrackedCoinsChanged (and trigger a refetch) on every settings write
    // even when the list did not change.
    if (JSON.stringify(coins) !== JSON.stringify(trackedCoins)) trackedCoins = coins
    if (prim !== primary) primary = prim
    if (iv !== intervalMin) intervalMin = iv
    if (flat !== flatThresholdPct) flatThresholdPct = flat
  }
  onSettingsChanged: applySettings()
  Component.onCompleted: applySettings()
  Component.onDestruction: Model.pollRelease(root)

  // What the bar paints: symbol, price, and a direction glyph. Moves within
  // the flat band (|24h| < flatThresholdPct, default ±0.5%) count as no
  // direction: plain foreground and "·". The glyph carries the same signal
  // for glanceability and stays readable even where the tint reads weakly.
  readonly property string labelSymbol: primaryRow ? primaryRow.symbol : ""
  readonly property string labelPrice: primaryRow && primaryRow.price !== null ? Model.formatUsd(primaryRow.price) : ""
  readonly property bool moveIsUp: primaryRow && primaryRow.change24h !== null && primaryRow.change24h >= root.flatThresholdPct
  readonly property bool moveIsDown: primaryRow && primaryRow.change24h !== null && primaryRow.change24h <= -root.flatThresholdPct
  readonly property string labelDirection: moveIsUp ? "▲" : (moveIsDown ? "▼" : "·")
  readonly property color priceColor: {
    var fg = root.bar ? root.bar.barForeground : Color.foreground
    if (root.moveIsUp) return "#7fc983"
    if (root.moveIsDown) return "#d4776f"
    return fg
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = root
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Fetches current markets. Does NOT forward to the panel: the panel's
  // own refresh() calls back into this (for its chart fetch), so
  // forwarding would recurse.
  function refresh() {
    if (root.pollLeader) {
      root.marketsFetch()
      return
    }
    // Ask the leader to re-check; fall back to fetching ourselves when
    // there is no live leader (single instance, or mid re-election).
    var leader = Model.pollLeaderInstance()
    if (leader && leader !== root) {
      try {
        if (typeof leader.refresh === "function") { leader.refresh(); return }
      } catch (e) {
        // Leader was destroyed; the heartbeat will re-elect shortly.
      }
    }
    root.marketsFetch()
  }

  // ---- shape contract for shell.summon/hide/toggle routing
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // ---- shell.json settings writes (clock's updateEntryInline pattern)

  function updateSettings(changes) {
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    for (var c in changes) entry[c] = changes[c]
    // Applied locally first so the change is visible immediately; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function updateSetting(key, value) {
    var changes = {}
    changes[key] = value
    root.updateSettings(changes)
  }

  // Track a new coin. Starts from trackedCoins (normalized, so manifest
  // defaults survive when shell.json has no coins key yet).
  function addCoin(id) {
    var next = root.trackedCoins.slice()
    if (next.indexOf(id) >= 0) return
    next.push(id)
    root.updateSetting("coins", next)
  }

  // Untrack a coin. The primary's fallback is computed against the OLD
  // primary and written in the same entry — writing it after `coins` would
  // compare against the already-updated primary and never fire.
  function removeCoin(id) {
    var current = root.trackedCoins.slice()
    var next = []
    for (var i = 0; i < current.length; i++) if (current[i] !== id) next.push(current[i])
    if (next.length === current.length) return
    root.updateSettings({ coins: next, primary: Model.primaryId(next, root.primary) })
  }

  function cyclePrimary() {
    if (root.trackedCoins.length < 2) return
    var idx = root.trackedCoins.indexOf(root.primary)
    var next = root.trackedCoins[(idx + 1) % root.trackedCoins.length]
    if (next) root.updateSetting("primary", next)
  }

  onTrackedCoinsChanged: Qt.callLater(refresh)

  // Stay clickable even with no data yet (error state, or every coin
  // removed) so the panel — the only way back to a working state — stays
  // reachable by mouse.
  visible: hasData || fetchError !== "" || trackedCoins.length === 0
  implicitWidth: contentRow.implicitWidth + Style.space(16)
  implicitHeight: barSize

  // ---- poll coordination ---------------------------------------------
  //
  // Leadership heartbeat + result fan-out. The leader claims once and then
  // only re-beats; everyone else pulls published rows whenever they are
  // newer than their own. A dead leader (widget destroyed with the monitor
  // it lived on) stops beating and is replaced within the 20s window.
  Timer {
    id: pollCoordination
    interval: 5000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      var wasLeader = root.pollLeader
      root.pollLeader = Model.pollClaim(root, Date.now())
      if (root.pollLeader || wasLeader) return
      var shared = Model.pollConsume(root)
      if (shared && shared.updated > root.lastUpdated.getTime()) {
        root.marketRows = shared.rows
        root.lastUpdated = new Date(shared.updated)
        root.fetchError = shared.error
      }
    }
  }

  Timer {
    id: poll
    interval: root.intervalMin * 60 * 1000
    repeat: true
    running: root.pollLeader
    triggeredOnStart: true
    onTriggered: root.marketsFetch()
  }

  // Bounded retry after a failed check (network down, rate limited,
  // CoinGecko error). Retries give up after four attempts and surface the
  // failure in the panel instead of retrying forever.
  Timer {
    id: retryTimer
    interval: 15000
    onTriggered: root.marketsFetch()
  }

  function marketsFetch() {
    if (marketsProc.running) {
      // A fetch is already in flight (e.g. refresh raced the poll tick).
      // Queue one re-run with the latest command rather than restarting
      // the process per call — repeated running=true would multiply API
      // calls.
      root.fetchQueued = true
      return
    }
    var ids = root.trackedCoins.join(",")
    if (ids === "") return
    marketsProc.command = ["curl", "-fsS", "--max-time", "15",
      "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=" + encodeURIComponent(ids)
      + "&order=market_cap_desc&sparkline=true&price_change_percentage=1h,24h,7d"]
    marketsProc.running = true
  }

  function handleFetchFailure() {
    root.fetchRetries++
    root.fetchError = "CoinGecko check failed" + (root.fetchRetries > 1 ? " · retry " + (root.fetchRetries - 1) + "/4" : "")
    Model.pollPublish(root, root.marketRows, root.lastUpdated.getTime(), root.fetchError)
    if (root.fetchRetries <= 4) retryTimer.restart()
  }

  // One call per check regardless of how many coins are tracked.
  Process {
    id: marketsProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var map = Model.parseMarkets(text)
        if (map) {
          root.fetchRetries = 0
          root.fetchError = ""
          root.marketRows = Model.orderRows(map, root.trackedCoins)
          root.lastUpdated = new Date()
          Model.pollPublish(root, root.marketRows, root.lastUpdated.getTime(), "")
        } else if (root.trackedCoins.length > 0) {
          root.handleFetchFailure()
        }
        if (root.fetchQueued) {
          root.fetchQueued = false
          Qt.callLater(root.marketsFetch)
        }
      }
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "crueber.omacoin"

    // Routed through broadcast so every monitor's instance opens/closes
    // together instead of only the one that happened to win the IPC
    // target registration.
    function open(): void { root.broadcast("open") }
    function close(): void { root.broadcast("close") }
    function show(): void { root.broadcast("open") }
    function hide(): void { root.broadcast("close") }
    function toggle(): void { root.broadcast("togglePanel") }
    function refresh(): void { root.broadcast("refresh") }

    // Scriptable state surface (same mutations the popup makes), with the
    // same clamps the popup applies.
    function addCoin(id: string): void { root.addCoin(id) }
    function removeCoin(id: string): void { root.removeCoin(id) }
    function setPrimary(id: string): void { root.updateSetting("primary", id) }
    function setIntervalMin(minutes: int): void { root.updateSetting("intervalMin", Model.clampInterval(minutes)) }
    function setFlatThreshold(pct: real): void { root.updateSetting("flatThresholdPct", Model.clampFlat(pct)) }
  }

  Row {
    id: contentRow
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      visible: !root.vertical && root.hasData
      anchors.verticalCenter: parent.verticalCenter
      text: root.labelSymbol
      color: Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.3)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }

    Text {
      visible: !root.vertical && root.hasData
      anchors.verticalCenter: parent.verticalCenter
      text: root.labelPrice
      color: root.priceColor
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }

    Text {
      visible: !root.vertical && root.hasData
      anchors.verticalCenter: parent.verticalCenter
      text: root.labelDirection
      color: root.priceColor
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    // Placeholder while there is nothing to show (fetch error, or every
    // coin removed) so the widget keeps an affordance to click.
    Text {
      visible: !root.hasData
      anchors.verticalCenter: parent.verticalCenter
      text: "—"
      color: Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.5)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }

    // Vertical bars get the compact form: symbol over price.
    Column {
      visible: root.vertical
      anchors.centerIn: parent
      spacing: 0

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.labelSymbol
        color: Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.3)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.hasData ? (root.labelPrice + " " + root.labelDirection) : "—"
        color: root.priceColor
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) root.cyclePrimary()
      else if (mouse.button === Qt.RightButton) root.refresh()
      else root.togglePanel()
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.hasData ? tooltipText() : "OmaCoin · click for details")
    onExited: if (root.bar) root.bar.hideTooltip(root)

    function tooltipText() {
      var bits = [root.primaryRow.name]
      if (root.primaryRow.change24h !== null) bits.push("24h " + Model.formatPct(root.primaryRow.change24h))
      if (root.fetchError !== "") bits.push(root.fetchError)
      if (root.lastUpdated.getTime() > 0) bits.push("updated " + Model.formatTime(root.lastUpdated))
      bits.push("click for details · middle: next coin")
      return bits.join(" · ")
    }
  }
}
