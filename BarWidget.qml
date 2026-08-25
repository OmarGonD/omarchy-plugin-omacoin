import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// OmaCoin bar widget: the primary coin's USD price and 24h change.
//
// Left click opens the panel (tracked coins, trends, add/remove, check
// frequency), middle click cycles the primary through the tracked coins,
// right click forces a refresh. All user state lives inline on this
// widget's shell.json entry (coins / primary / intervalMin), written
// through bar.shell.updateEntryInline so every bar instance stays in sync.
BarWidget {
  id: root
  moduleName: "crueber.omacoin"

  // Normalized /coins/markets rows, ordered along the tracked-coin list.
  // Kept on failure so stale prices stay up while a retry runs.
  property var marketRows: []
  property date lastUpdated: new Date(0)

  // Settings-derived state. QML's dependency tracking does not reliably
  // follow `settings` reads made inside the base class's setting() helper
  // (observed: bindings evaluated once at defaults and never refreshed
  // after the host injects settings), so these are plain properties
  // recomputed by applySettings() instead of bindings.
  property var trackedCoins: ["bitcoin", "ethereum"]
  property string primary: "bitcoin"
  property int intervalMin: 60
  readonly property var primaryRow: Model.rowById(marketRows, primary)
  readonly property bool hasData: primaryRow !== null

  function applySettings() {
    trackedCoins = Model.coinList(setting("coins", ["bitcoin", "ethereum"]))
    primary = Model.primaryId(trackedCoins, setting("primary", "bitcoin"))
    intervalMin = Model.clampInterval(setting("intervalMin", 60))
  }
  onSettingsChanged: applySettings()
  Component.onCompleted: applySettings()

  // What the bar paints.
  readonly property string labelSymbol: primaryRow ? primaryRow.symbol : ""
  readonly property string labelPrice: primaryRow && primaryRow.price !== null ? Model.formatUsd(primaryRow.price) : ""
  readonly property string labelChange: primaryRow && primaryRow.change24h !== null ? Model.formatPct(primaryRow.change24h) : ""
  readonly property color changeColor: primaryRow && primaryRow.change24h !== null
    ? (primaryRow.change24h >= 0 ? "#7fc983" : "#d4776f")
    : Color.muted

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
    marketsProc.start()
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

  function updateSetting(key, value) {
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    entry[key] = value
    // Applied locally first so the change is visible immediately; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Track a new coin. Starts from trackedCoins (normalized, so manifest
  // defaults survive when shell.json has no coins key yet); when the list
  // was empty the primary falls back to the new coin automatically.
  function addCoin(id) {
    var next = root.trackedCoins.slice()
    if (next.indexOf(id) >= 0) return
    next.push(id)
    root.updateSetting("coins", next)
  }

  // Untrack a coin; the primary falls back to the first coin left.
  function removeCoin(id) {
    var current = root.trackedCoins.slice()
    var next = []
    for (var i = 0; i < current.length; i++) if (current[i] !== id) next.push(current[i])
    if (next.length === current.length) return
    root.updateSetting("coins", next)
    if (Model.primaryId(next, root.primary) !== root.primary)
      root.updateSetting("primary", Model.primaryId(next, root.primary))
  }
  function cyclePrimary() {
    var idx = root.trackedCoins.indexOf(root.primary)
    var next = root.trackedCoins[(idx + 1) % root.trackedCoins.length]
    if (next) root.updateSetting("primary", next)
  }
  onTrackedCoinsChanged: Qt.callLater(refresh)

  visible: hasData
  implicitWidth: hasData ? contentRow.implicitWidth + Style.space(16) : 0
  implicitHeight: barSize

  Timer {
    id: poll
    interval: root.intervalMin * 60 * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: marketsProc.start()
  }

  // One call per check regardless of how many coins are tracked.
  Process {
    id: marketsProc

    function start() {
      var ids = root.trackedCoins.join(",")
      if (ids === "") return
      command = ["curl", "-fsS", "--max-time", "15",
        "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=" + encodeURIComponent(ids)
        + "&order=market_cap_desc&sparkline=true&price_change_percentage=1h,24h,7d"]
      running = true
    }

    stdout: StdioCollector {
      onStreamFinished: {
        var map = Model.parseMarkets(text)
        if (!map) return
        root.marketRows = Model.orderRows(map, root.trackedCoins)
        root.lastUpdated = new Date()
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

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.broadcast("refresh") }

    // Scriptable state surface (same mutations the popup makes).
    function addCoin(id: string): void { root.addCoin(id) }
    function removeCoin(id: string): void { root.removeCoin(id) }
    function setPrimary(id: string): void { root.updateSetting("primary", id) }
    function setIntervalMin(minutes: int): void { root.updateSetting("intervalMin", minutes) }
  }

  Row {
    id: contentRow
    anchors.centerIn: parent
    spacing: Style.space(6)
    visible: root.hasData

    Text {
      visible: !root.vertical
      anchors.verticalCenter: parent.verticalCenter
      text: root.labelSymbol
      color: Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.3)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }

    Text {
      visible: !root.vertical
      anchors.verticalCenter: parent.verticalCenter
      text: root.labelPrice
      color: root.bar ? root.bar.barForeground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }

    Text {
      visible: !root.vertical && root.labelChange !== ""
      anchors.verticalCenter: parent.verticalCenter
      text: root.labelChange
      color: root.changeColor
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
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
        text: root.labelPrice
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.hasData ? Qt.PointingHandCursor : Qt.ArrowCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (!root.hasData) return
      if (mouse.button === Qt.MiddleButton) root.cyclePrimary()
      else if (mouse.button === Qt.RightButton) root.refresh()
      else root.togglePanel()
    }
    onEntered: if (root.bar && root.hasData) root.bar.showTooltip(root, tooltipText())
    onExited: if (root.bar) root.bar.hideTooltip(root)

    function tooltipText() {
      if (!root.primaryRow) return ""
      var bits = [root.primaryRow.name]
      if (root.primaryRow.change24h !== null) bits.push("24h " + Model.formatPct(root.primaryRow.change24h))
      if (root.lastUpdated.getTime() > 0) bits.push("updated " + Model.formatTime(root.lastUpdated))
      bits.push("click for details · middle: next coin")
      return bits.join(" · ")
    }
  }
}
