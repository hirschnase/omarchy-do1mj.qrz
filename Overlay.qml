import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string callsignText: ""
  property string pageKind: ""
  property bool lookingUp: false
  property string statusText: ""
  property int requestSerial: 0
  property string lookupResultDir: Quickshell.env("HOME") + "/.cache/do1mj.qrz"
  property string activeCallsign: ""
  property string resultCallsign: ""
  property string resultCountry: ""
  property string resultFlag: ""
  property string resultPhoto: ""
  property string resultQsl: ""
  property string resultManager: ""
  property string resultLookups: ""
  property string resultBio: ""
  property string resultError: ""
  property string resultUrl: ""
  property string xmlName: ""
  property string xmlEmail: ""
  property string xmlAddress: ""
  property string xmlGrid: ""
  property string xmlLat: ""
  property string xmlLon: ""
  property string xmlMapsUrl: ""
  property string xmlCounty: ""
  property string xmlClass: ""
  property string xmlCq: ""
  property string xmlItu: ""
  property string xmlQslmgr: ""
  property string xmlLotw: ""
  property string xmlEqsl: ""
  property string xmlMqsl: ""

  property bool settingsOpen: false
  property string settingsUsername: ""
  property bool settingsHasPassword: false
  property bool settingsHasSession: false
  property string settingsStatus: ""
  property bool settingsOk: false
  property bool settingsBusy: false
  property string pendingLookup: ""
  property var workQueue: []

  // Minimum number of characters typed before an automatic (debounced)
  // lookup fires. Pressing Enter always searches immediately regardless
  // of this minimum, since that is an explicit user action.
  readonly property int minAutoSearchLength: 5

  // Pixels the result view scrolls per mouse-wheel notch (120 angleDelta
  // units). Qt's Flickable default step feels sluggish for a page-like
  // reading area, so wheel scrolling is handled explicitly below.
  readonly property int wheelScrollStep: 320

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(820), panel.width - Style.gapsOut * 2)
  property int compactHeight: Style.space(118)
  property int expandedHeight: Math.min(Style.space(720), panel.height - Style.gapsOut * 2)
  readonly property bool expanded: root.lookingUp || root.pageKind !== "" || root.settingsOpen
  property int cardHeight: root.expanded ? root.expandedHeight : root.compactHeight

  // A light, readable "page" theme for the fetched QRZ content, independent
  // of the overlay's own dark chrome — this is meant to read like a web page.
  property color resultBg: "#f7f6f2"
  property color resultSurface: "#ffffff"
  property color resultBorder: "#e2e0da"
  property color resultFg: "#22252b"
  property color resultMuted: "#5b6472"
  property color resultAccent: "#2563eb"

  function toHex2(v) {
    var n = Math.round(Math.max(0, Math.min(1, v)) * 255)
    var h = n.toString(16)
    return h.length === 1 ? "0" + h : h
  }

  function colorHex(c) {
    return "#" + toHex2(c.r) + toHex2(c.g) + toHex2(c.b)
  }

  // Wraps the sanitized QRZ biography HTML with an inline stylesheet so it
  // reads well against the light result surface (Qt's rich text renderer
  // understands this subset of CSS).
  readonly property string styledBio: root.resultBio ? (
    "<style>"
    + "body,p,li,div,span,td,th { font-family: sans-serif; font-size: " + Style.font.body + "px; color: " + root.colorHex(root.resultFg) + "; line-height: 1.5; }"
    + "h1,h2,h3,h4 { color: " + root.colorHex(root.resultFg) + "; margin: 0.6em 0 0.3em; }"
    + "a { color: " + root.colorHex(root.resultAccent) + "; text-decoration: underline; }"
    + "img { max-width: 100%; height: auto; border-radius: 6px; margin: 6px 0; }"
    + "table { border-collapse: collapse; width: 100%; }"
    + "td, th { padding: 4px 6px; border-bottom: 1px solid " + root.colorHex(root.resultBorder) + "; }"
    + "</style>"
    + root.resultBio
  ) : ""

  function lookupScript() {
    var dir = root.manifest && root.manifest.__sourceDir ? String(root.manifest.__sourceDir) : ""
    if (dir)
      return dir.replace(/\/$/, "") + "/scripts/qrz-lookup.py"
    var url = String(Qt.resolvedUrl("scripts/qrz-lookup.py"))
    if (url.indexOf("file://") === 0) {
      url = url.slice(7)
      if (url.indexOf("localhost/") === 0)
        url = url.slice(9)
    }
    return url
  }

  function xmlScript() {
    var dir = root.manifest && root.manifest.__sourceDir ? String(root.manifest.__sourceDir) : ""
    if (dir)
      return dir.replace(/\/$/, "") + "/scripts/qrz-xml.py"
    var url = String(Qt.resolvedUrl("scripts/qrz-xml.py"))
    if (url.indexOf("file://") === 0) {
      url = url.slice(7)
      if (url.indexOf("localhost/") === 0)
        url = url.slice(9)
    }
    return url
  }

  function normalizeCallsign(value) {
    return String(value || "").replace(/\s+/g, "").toUpperCase()
  }

  function isValidCallsign(value) {
    return /^(?:[A-Z0-9]{1,3}\/)?[A-Z0-9]{1,3}[0-9][A-Z0-9]{0,5}(?:\/[A-Z0-9]{1,8})?$/.test(value)
  }

  function hasUnsafeUrlChars(value) {
    var s = String(value || "")
    for (var i = 0; i < s.length; i++) {
      var code = s.charCodeAt(i)
      if (code <= 32 || code === 127 || code === 92)
        return true
    }
    return false
  }

  function parseHttpUrl(url) {
    var s = String(url || "").trim()
    if (!s || root.hasUnsafeUrlChars(s))
      return null
    var match = s.match(/^(https?):\/\/([^\/?#]+)(\/[^?#]*)?(\?[^#]*)?(#.*)?$/i)
    if (!match)
      return null
    var netloc = match[2]
    var at = netloc.lastIndexOf("@")
    if (at !== -1)
      netloc = netloc.slice(at + 1)
    if (netloc.charAt(0) === "[")
      return null
    var host = netloc
    var port = ""
    var colon = host.lastIndexOf(":")
    if (colon !== -1) {
      port = host.slice(colon + 1)
      host = host.slice(0, colon)
      if (!/^\d+$/.test(port) || (port !== "80" && port !== "443"))
        return null
    }
    host = host.toLowerCase()
    while (host.length && host.charAt(host.length - 1) === ".")
      host = host.slice(0, host.length - 1)
    if (!/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(host))
      return null
    if (/^\d+\.\d+\.\d+\.\d+$/.test(host))
      return null
    return {
      host: host,
      path: match[3] || "",
      query: match[4] ? match[4].slice(1) : "",
      fragment: match[5] ? match[5].slice(1) : ""
    }
  }

  function isQrzHost(host) {
    var h = String(host || "")
    return h === "qrz.com" || h.slice(-8) === ".qrz.com"
  }

  function safeQrzUrl(url) {
    var parsed = root.parseHttpUrl(url)
    if (!parsed || !root.isQrzHost(parsed.host))
      return ""
    var out = "https://" + parsed.host + parsed.path
    if (parsed.query)
      out += "?" + parsed.query
    if (parsed.fragment)
      out += "#" + parsed.fragment
    return out
  }

  function safeMapsUrl(url) {
    var parsed = root.parseHttpUrl(url)
    if (!parsed)
      return ""
    if (parsed.host !== "www.google.com" && parsed.host !== "google.com" && parsed.host !== "maps.google.com")
      return ""
    if (parsed.path.indexOf("/maps") !== 0)
      return ""
    if (!/^q=-?\d+(?:\.\d+)?,-?\d+(?:\.\d+)?$/.test(parsed.query))
      return ""
    if (parsed.fragment)
      return ""
    return "https://" + parsed.host + parsed.path + "?" + parsed.query
  }

  function safeEmail(value) {
    var s = String(value || "").trim()
    if (!/^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,24}$/.test(s))
      return ""
    return s
  }

  function safeMailto(url) {
    var s = String(url || "").trim()
    if (!s || root.hasUnsafeUrlChars(s))
      return ""
    var match = s.match(/^mailto:([^?#]*)/i)
    if (!match)
      return ""
    var addr = match[1]
    try { addr = decodeURIComponent(addr) } catch (e) { return "" }
    addr = root.safeEmail(addr)
    return addr ? ("mailto:" + addr) : ""
  }

  function openSafeUrl(url) {
    var s = String(url || "").trim()
    var safe = s.slice(0, 7).toLowerCase() === "mailto:" ? root.safeMailto(s) : (root.safeQrzUrl(s) || root.safeMapsUrl(s))
    if (safe)
      Qt.openUrlExternally(safe)
  }

  function rewriteQuotedAttr(html, attrName, kind) {
    var text = String(html || "")
    var lower = text.toLowerCase()
    var needle = attrName + "="
    var out = ""
    var i = 0
    while (i < text.length) {
      var pos = lower.indexOf(needle, i)
      while (pos !== -1 && pos > 0 && /[A-Za-z0-9_-]/.test(text.charAt(pos - 1)))
        pos = lower.indexOf(needle, pos + 1)
      if (pos === -1) {
        out += text.slice(i)
        break
      }
      out += text.slice(i, pos)
      var cursor = pos + needle.length
      while (cursor < text.length && (text.charAt(cursor) === " " || text.charAt(cursor) === "\t"))
        cursor += 1
      var quote = text.charAt(cursor)
      if (quote !== '"' && quote !== "'") {
        out += text.slice(pos, cursor)
        i = cursor
        continue
      }
      var end = text.indexOf(quote, cursor + 1)
      if (end === -1) {
        out += text.slice(pos)
        break
      }
      var raw = text.slice(cursor + 1, end)
      var safe = ""
      if (kind === "src")
        safe = root.safeQrzUrl(raw)
      else if (String(raw).trim().slice(0, 7).toLowerCase() === "mailto:")
        safe = root.safeMailto(raw)
      else
        safe = root.safeQrzUrl(raw) || root.safeMapsUrl(raw)
      if (kind === "src")
        out += safe ? (attrName + '="' + safe + '"') : ""
      else
        out += attrName + '="' + (safe || "#") + '"'
      i = end + 1
    }
    return out
  }

  function restrictHtmlUrls(html) {
    var text = root.rewriteQuotedAttr(html, "src", "src")
    text = root.rewriteQuotedAttr(text, "href", "href")
    return text
  }

  function resetResult() {
    root.pageKind = ""
    root.resultCallsign = ""
    root.resultCountry = ""
    root.resultFlag = ""
    root.resultPhoto = ""
    root.resultQsl = ""
    root.resultManager = ""
    root.resultLookups = ""
    root.resultBio = ""
    root.resultError = ""
    root.resultUrl = ""
    root.xmlName = ""
    root.xmlEmail = ""
    root.xmlAddress = ""
    root.xmlGrid = ""
    root.xmlLat = ""
    root.xmlLon = ""
    root.xmlMapsUrl = ""
    root.xmlCounty = ""
    root.xmlClass = ""
    root.xmlCq = ""
    root.xmlItu = ""
    root.xmlQslmgr = ""
    root.xmlLotw = ""
    root.xmlEqsl = ""
    root.xmlMqsl = ""
    detailModel.clear()
  }

  function applyDetails(list) {
    detailModel.clear()
    if (!list || !list.length) return
    var signedIn = root.settingsHasSession || root.xmlEmail !== "" || root.xmlName !== ""
    for (var i = 0; i < list.length; i++) {
      var line = String(list[i])
      var lower = line.toLowerCase()
      if (signedIn && (lower.indexOf("login is required") !== -1 || lower.indexOf("login required to view") !== -1))
        continue
      detailModel.append({ line: line })
    }
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    root.opened = true
    root.lookingUp = false
    root.resetResult()
    root.callsignText = root.normalizeCallsign(payload.callsign || "")
    callsignField.text = root.callsignText
    root.statusText = ""
    if (!root.callsignText)
      root.loadSettings()
    Qt.callLater(function() {
      callsignField.forceActiveFocus()
      if (root.callsignText.length) {
        callsignField.selectAll()
        root.lookupNow()
      }
    })
  }

  function close() {
    lookupDebounce.stop()
    workDelay.stop()
    root.workQueue = []
    root.pendingLookup = ""
    lookupProc.running = false
    settingsProc.running = false
    root.opened = false
    root.lookingUp = false
    root.settingsBusy = false
    root.resetResult()
    root.callsignText = ""
    root.statusText = ""
    root.activeCallsign = ""
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "do1mj.qrz")
  }

  function clearCallsign() {
    callsignField.text = ""
    root.onCallsignEdited("")
    callsignField.forceActiveFocus()
  }

  function closeSettings() {
    root.settingsOpen = false
    Qt.callLater(function() { callsignField.forceActiveFocus() })
  }

  function cancelSettings() {
    root.dropQueuedWork("settings")
    root.settingsBusy = false
    settingsUserField.text = root.settingsUsername
    settingsPassField.text = ""
    root.settingsStatus = ""
    root.closeSettings()
  }

  function toggleSettings() {
    if (root.settingsOpen) {
      root.closeSettings()
      return
    }
    root.settingsOpen = true
    root.loadSettings()
    Qt.callLater(function() { settingsUserField.forceActiveFocus() })
  }

  function settingsPayload() {
    return JSON.stringify({
      username: settingsUserField.text,
      password: settingsPassField.text
    }) + "\n"
  }

  function dropQueuedWork(kind) {
    var next = []
    for (var i = 0; i < root.workQueue.length; i++) {
      var item = root.workQueue[i]
      if (kind === "settings") {
        if (item.kind === "load" || item.kind === "save" || item.kind === "check") continue
      } else if (item.kind === kind) {
        continue
      }
      next.push(item)
    }
    root.workQueue = next
    if (kind === "settings" && settingsProc.running) {
      settingsProc.ignoreResult = true
      settingsProc.running = false
    }
    if (kind === "lookup" && lookupProc.running) {
      lookupProc.ignoreResult = true
      lookupProc.running = false
    }
  }

  function enqueueWork(kind, args, stdinText, serial) {
    var queue = root.workQueue.slice()
    queue.push({ kind: kind, args: args, stdinText: stdinText || "", serial: serial || 0 })
    root.workQueue = queue
    root.pumpWork()
  }

  function workBusy() {
    return lookupProc.running || settingsProc.running || workDelay.running
  }

  function pumpWork() {
    if (root.workBusy()) return
    if (!root.workQueue.length) return
    var queue = root.workQueue.slice()
    var job = queue.shift()
    root.workQueue = queue
    if (job.kind === "lookup") {
      lookupProc.ignoreResult = false
      lookupProc._serial = job.serial
      lookupProc.command = job.args
      lookupProc.running = true
      return
    }
    settingsProc.kind = job.kind
    settingsProc.ignoreResult = false
    settingsProc.pending = job.stdinText
    settingsProc.command = job.args
    settingsProc.running = true
  }

  function loadSettings() {
    root.enqueueWork("load", ["python3", root.xmlScript(), "load"], "")
  }

  function saveSettings() {
    root.settingsBusy = true
    root.settingsStatus = "Saving…"
    root.enqueueWork("save", ["python3", root.xmlScript(), "save"], root.settingsPayload())
  }

  function checkSettings() {
    root.settingsBusy = true
    root.settingsStatus = "Checking credentials…"
    root.enqueueWork("check", ["python3", root.xmlScript(), "check"], root.settingsPayload())
  }

  function applySettings(raw) {
    root.settingsBusy = false
    var payload = null
    try { payload = JSON.parse(String(raw || "")) } catch (e) { payload = null }
    if (!payload) {
      root.settingsOk = false
      root.settingsStatus = "Could not read settings response"
    } else {
      if (payload.username !== undefined)
        root.settingsUsername = String(payload.username || "")
      if (payload.hasPassword !== undefined)
        root.settingsHasPassword = payload.hasPassword === true
      if (payload.hasSession !== undefined)
        root.settingsHasSession = payload.hasSession === true
      if (settingsProc.kind === "load") {
        settingsUserField.text = root.settingsUsername
        settingsPassField.text = ""
        var authError = String(payload.authError || "")
        if (authError) {
          // A previous automatic session renewal failed and hasn't been
          // cleared by a fresh Save/Check yet — surface that here rather
          // than silently retrying it on every lookup.
          root.settingsStatus = "Automatic sign-in failed: " + authError + " — update your credentials and save."
          root.settingsOk = false
        } else {
          root.settingsStatus = root.settingsHasSession ? "Signed in" : (root.settingsHasPassword ? "Password saved" : "")
          root.settingsOk = root.settingsHasSession
        }
      } else {
        root.settingsOk = payload.ok === true
        root.settingsStatus = payload.ok ? "Credentials accepted" : (payload.error || "Login failed")
      }
    }
  }

  function onCallsignEdited(value) {
    var next = root.normalizeCallsign(value)
    if (next === root.callsignText) return
    if (root.lookingUp && next === root.activeCallsign) {
      root.callsignText = next
      return
    }
    root.callsignText = next
    root.lookingUp = false
    root.pendingLookup = ""
    root.resetResult()
    root.statusText = ""
    if (!next) {
      lookupDebounce.stop()
      return
    }
    if (next.length >= root.minAutoSearchLength && root.isValidCallsign(next))
      lookupDebounce.restart()
    else
      lookupDebounce.stop()
  }

  function lookupNow() {
    lookupDebounce.stop()
    root.startLookup(root.normalizeCallsign(callsignField.text))
  }

  function startLookup(callsign) {
    if (!callsign) {
      root.lookingUp = false
      root.resetResult()
      root.statusText = ""
      return
    }
    if (!root.isValidCallsign(callsign)) {
      root.lookingUp = false
      root.resetResult()
      root.statusText = "Enter a valid amateur radio callsign"
      return
    }
    root.callsignText = callsign
    root.activeCallsign = callsign
    root.resetResult()
    root.lookingUp = true
    root.statusText = "Looking up " + callsign + "…"
    root.requestSerial += 1
    // Each request writes to a brand-new file name rather than a shared
    // fixed path. A shared path can still hold a stale result from an
    // earlier session/search; watching it means a reload() right before the
    // new script even starts can briefly apply that old, unrelated result
    // and (since it clears "lookingUp") cause the real fresh result to be
    // silently ignored when it lands moments later.
    var resultPath = root.lookupResultDir + "/lookup-" + root.requestSerial + "-" + Date.now() + ".json"
    lookupWatch.path = resultPath
    Quickshell.execDetached(["python3", root.lookupScript(), callsign, resultPath, String(root.requestSerial)])
    lookupTimeout.restart()
  }

  function applyLookup(raw, serial) {
    if (serial !== root.requestSerial) return
    var payload = null
    try { payload = JSON.parse(String(raw || "")) } catch (e) { payload = null }
    if (!payload) {
      root.lookingUp = false
      root.pageKind = "error"
      root.resultCallsign = root.activeCallsign
      root.resultError = "Could not parse QRZ response"
      root.statusText = ""
      return
    }
    root.resultCallsign = String(payload.callsign || root.activeCallsign)
    root.resultCountry = String(payload.country || "")
    root.resultFlag = root.safeQrzUrl(payload.flag || "")
    root.resultQsl = String(payload.qsl || "")
    root.resultManager = String(payload.manager || "")
    root.resultLookups = String(payload.lookups || "")
    root.resultError = String(payload.error || "")
    root.resultUrl = root.safeQrzUrl(payload.url || "")
    root.xmlName = String(payload.xmlName || "")
    root.xmlEmail = root.safeEmail(payload.xmlEmail || "")
    root.xmlAddress = String(payload.xmlAddress || "")
    root.xmlGrid = String(payload.xmlGrid || "")
    root.xmlLat = String(payload.xmlLat || "")
    root.xmlLon = String(payload.xmlLon || "")
    root.xmlMapsUrl = root.safeMapsUrl(payload.xmlMapsUrl || "")
    root.xmlCounty = String(payload.xmlCounty || "")
    root.xmlClass = String(payload.xmlClass || "")
    root.xmlCq = String(payload.xmlCq || "")
    root.xmlItu = String(payload.xmlItu || "")
    root.xmlQslmgr = String(payload.xmlQslmgr || "")
    root.xmlLotw = String(payload.xmlLotw || "")
    root.xmlEqsl = String(payload.xmlEqsl || "")
    root.xmlMqsl = String(payload.xmlMqsl || "")
    root.applyDetails(payload.details)
    root.lookingUp = false
    if (payload.found)
      root.pageKind = "result"
    else if (payload.ok)
      root.pageKind = "missing"
    else
      root.pageKind = "error"
    root.statusText = ""
    var photo = root.safeQrzUrl(payload.photo || "")
    var bio = root.restrictHtmlUrls(payload.biodataHtml || "")
    Qt.callLater(function() {
      if (serial !== root.requestSerial) return
      root.resultPhoto = photo
      root.resultBio = bio
    })
  }

  ListModel { id: detailModel }

  Timer {
    id: lookupDebounce
    interval: 450
    repeat: false
    onTriggered: root.lookupNow()
  }

  FileView {
    id: lookupWatch
    path: ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      if (!root.lookingUp) return
      var raw = ""
      try { raw = text() } catch (e) { return }
      var payload = null
      try { payload = JSON.parse(String(raw || "")) } catch (e) { payload = null }
      var serial = payload && payload.serial !== undefined ? Number(payload.serial) : root.requestSerial
      Qt.callLater(function() { root.applyLookup(raw, serial) })
    }
  }

  Timer {
    id: lookupTimeout
    interval: 20000
    repeat: false
    onTriggered: {
      if (!root.lookingUp || root.pageKind !== "") return
      root.lookingUp = false
      root.pageKind = "error"
      root.resultCallsign = root.activeCallsign
      root.resultError = "Lookup timed out"
      root.statusText = ""
    }
  }

  Timer {
    id: workDelay
    interval: 80
    repeat: false
    onTriggered: root.pumpWork()
  }

  Process {
    id: lookupProc
    property int _serial: 0
    property bool ignoreResult: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        var serial = lookupProc._serial
        if (lookupProc.ignoreResult) return
        Qt.callLater(function() { root.applyLookup(raw, serial) })
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      var serial = lookupProc._serial
      Qt.callLater(function() {
        if (lookupProc.ignoreResult) return
    if (serial !== root.requestSerial) return
    lookupTimeout.stop()
        if (root.pageKind !== "") return
        if (root.lookingUp && exitCode !== 0) {
          root.lookingUp = false
          root.pageKind = "error"
          root.resultCallsign = root.activeCallsign
          root.resultError = "QRZ lookup failed (exit " + exitCode + ")"
          root.statusText = ""
        }
      })
      workDelay.restart()
    }
  }

  Process {
    id: settingsProc
    property string kind: ""
    property string pending: ""
    property bool ignoreResult: false
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        if (settingsProc.ignoreResult) return
        Qt.callLater(function() { root.applySettings(raw) })
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      if (settingsProc.pending) {
        write(settingsProc.pending)
        settingsProc.pending = ""
      }
    }
    onExited: function(exitCode) {
      Qt.callLater(function() {
        if (settingsProc.ignoreResult) return
        if ((settingsProc.kind === "save" || settingsProc.kind === "check") && root.settingsBusy && exitCode !== 0) {
          root.settingsBusy = false
          root.settingsOk = false
          root.settingsStatus = "Settings command failed"
        }
      })
      workDelay.restart()
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "do1mj-qrz"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      Behavior on height {
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        Item {
          id: callsignRow
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: callsignField.implicitHeight

          TextField {
            id: callsignField
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: clearButton.left
            anchors.rightMargin: Style.spacing.sm
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.capitalization: Font.AllUppercase
            foreground: root.foreground
            placeholderText: "Callsign"
            inputMethodHints: Qt.ImhUppercaseOnly | Qt.ImhLatinOnly
            onTextChanged: root.onCallsignEdited(text)
            onAccepted: root.lookupNow()
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                if (root.settingsOpen) root.toggleSettings()
                else if (callsignField.text !== "") root.clearCallsign()
                else root.dismiss()
                event.accepted = true
              }
            }
          }

          Rectangle {
            id: clearButton
            width: Style.space(28)
            height: Style.space(28)
            radius: width / 2
            anchors.right: settingsButton.left
            anchors.rightMargin: Style.spacing.xs
            anchors.verticalCenter: callsignField.verticalCenter
            visible: callsignField.text !== ""
            color: clearMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12) : "transparent"

            Text {
              anchors.centerIn: parent
              text: "\u2715"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            MouseArea {
              id: clearMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.clearCallsign()
            }
          }

          Rectangle {
            id: settingsButton
            width: Style.space(28)
            height: Style.space(28)
            radius: width / 2
            anchors.right: parent.right
            anchors.verticalCenter: callsignField.verticalCenter
            color: (root.settingsOpen || settingsHover.containsMouse) ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12) : "transparent"

            Text {
              anchors.centerIn: parent
              text: "\u2699"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            MouseArea {
              id: settingsHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleSettings()
            }
          }
        }

        Item {
          anchors.top: callsignRow.bottom
          anchors.topMargin: root.contentSpacing
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          visible: root.expanded

          Rectangle {
            id: resultSurface
            anchors.fill: parent
            radius: root.cornerRadius
            color: root.resultBg
            border.width: 1
            border.color: root.resultBorder

            Column {
              anchors.centerIn: parent
              spacing: Style.spacing.md
              visible: root.lookingUp && !root.settingsOpen
              width: parent.width

              Item {
                width: Style.space(28)
                height: width
                anchors.horizontalCenter: parent.horizontalCenter
                RotationAnimation on rotation {
                  running: root.lookingUp
                  from: 0
                  to: 360
                  loops: Animation.Infinite
                  duration: 900
                }
                Text {
                  anchors.centerIn: parent
                  text: "\uf110"
                  color: root.resultAccent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              Text {
                width: parent.width
                text: root.statusText || ("Looking up " + root.activeCallsign + "…")
                color: root.resultFg
                opacity: 0.85
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Column {
              anchors.fill: parent
              anchors.margins: root.contentMargin
              spacing: Style.spacing.md
              visible: root.settingsOpen

              Text {
                width: parent.width
                text: "QRZ.com login"
                color: root.resultFg
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                width: parent.width
                text: "Saved in ~/.config/do1mj.qrz/settings.json (directory mode 700, file mode 600). The session key is reused so you stay signed in."
                color: root.resultMuted
                wrapMode: Text.Wrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              TextField {
                id: settingsUserField
                width: parent.width
                foreground: root.resultFg
                placeholderText: "Username"
                font.family: root.fontFamily
              }

              TextField {
                id: settingsPassField
                width: parent.width
                foreground: root.resultFg
                placeholderText: root.settingsHasPassword ? "Password (saved)" : "Password"
                password: true
                font.family: root.fontFamily
              }

              Row {
                spacing: Style.spacing.md

                Rectangle {
                  width: saveLabel.implicitWidth + Style.spacing.controlPaddingX * 2
                  height: Style.spacing.controlHeight
                  radius: root.cornerRadius
                  color: saveHover.containsMouse ? root.resultAccent : "#1d4ed8"
                  enabled: !root.settingsBusy

                  Text {
                    id: saveLabel
                    anchors.centerIn: parent
                    text: "Save"
                    color: "#ffffff"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  MouseArea {
                    id: saveHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.saveSettings()
                  }
                }

                Rectangle {
                  width: checkLabel.implicitWidth + Style.spacing.controlPaddingX * 2
                  height: Style.spacing.controlHeight
                  radius: root.cornerRadius
                  color: checkHover.containsMouse ? "#374151" : "#4b5563"
                  enabled: !root.settingsBusy

                  Text {
                    id: checkLabel
                    anchors.centerIn: parent
                    text: "Check credentials"
                    color: "#ffffff"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  MouseArea {
                    id: checkHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.checkSettings()
                  }
                }

                Rectangle {
                  width: cancelLabel.implicitWidth + Style.spacing.controlPaddingX * 2
                  height: Style.spacing.controlHeight
                  radius: root.cornerRadius
                  color: cancelHover.containsMouse ? "#6b7280" : "#9ca3af"

                  Text {
                    id: cancelLabel
                    anchors.centerIn: parent
                    text: "Cancel"
                    color: "#111827"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  MouseArea {
                    id: cancelHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.cancelSettings()
                  }
                }

                Rectangle {
                  width: closeLabel.implicitWidth + Style.spacing.controlPaddingX * 2
                  height: Style.spacing.controlHeight
                  radius: root.cornerRadius
                  color: closeHover.containsMouse ? "#374151" : "#4b5563"

                  Text {
                    id: closeLabel
                    anchors.centerIn: parent
                    text: "Close"
                    color: "#ffffff"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  MouseArea {
                    id: closeHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.closeSettings()
                  }
                }
              }

              Text {
                width: parent.width
                visible: root.settingsStatus !== ""
                text: root.settingsStatus
                color: root.settingsOk ? "#15803d" : "#b91c1c"
                wrapMode: Text.Wrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }

            Item {
              id: resultPane
              anchors.fill: parent
              anchors.margins: root.contentMargin
              visible: !root.lookingUp && !root.settingsOpen && root.pageKind !== ""

              Flickable {
                id: resultsFlick
                anchors.fill: parent
                clip: true
                contentWidth: resultPane.width
                contentHeight: resultBody.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick

                // Flickable's own wheel handling scrolls in small, sluggish
                // steps. Handle the wheel ourselves with a much larger
                // per-notch distance and mark the event accepted so
                // Flickable's built-in handling doesn't also move it (which
                // would otherwise double up / fight this). Accept every
                // pointer device — restricting to PointerDevice.Mouse can
                // silently miss real hardware and fall back to the slow
                // default path.
                WheelHandler {
                  onWheel: function(event) {
                    var notches = event.angleDelta.y / 120
                    if (notches === 0) return
                    var maxY = Math.max(0, resultsFlick.contentHeight - resultsFlick.height)
                    resultsFlick.contentY = Math.max(0, Math.min(maxY, resultsFlick.contentY - notches * root.wheelScrollStep))
                    event.accepted = true
                  }
                }

                Column {
                  id: resultBody
                  width: resultPane.width
                  spacing: Style.spacing.md

                  Column {
                    width: parent.width
                    spacing: Style.spacing.sm
                    visible: root.pageKind === "missing"

                    Text {
                      width: parent.width
                      text: "No results"
                      color: root.resultFg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      horizontalAlignment: Text.AlignHCenter
                    }

                    Text {
                      width: parent.width
                      text: "The search for \"" + root.resultCallsign + "\" produced no results."
                      color: root.resultMuted
                      wrapMode: Text.Wrap
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      horizontalAlignment: Text.AlignHCenter
                    }
                  }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.sm
                    visible: root.pageKind === "error"

                    Text {
                      width: parent.width
                      text: "Lookup failed"
                      color: root.resultFg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      horizontalAlignment: Text.AlignHCenter
                    }

                    Text {
                      width: parent.width
                      text: root.resultError || "Unknown error"
                      color: root.resultMuted
                      wrapMode: Text.Wrap
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      horizontalAlignment: Text.AlignHCenter
                    }
                  }

                  Column {
                    width: parent.width
                    spacing: Style.spacing.md
                    visible: root.pageKind === "result"

                    Row {
                      width: parent.width
                      spacing: Style.spacing.md

                      Rectangle {
                        visible: root.resultPhoto !== ""
                        width: Style.space(120)
                        height: Style.space(120)
                        radius: Style.space(6)
                        color: root.resultSurface
                        border.width: 1
                        border.color: root.resultBorder
                        clip: true

                        Image {
                          anchors.fill: parent
                          anchors.margins: 1
                          source: root.safeQrzUrl(root.resultPhoto)
                          fillMode: Image.PreserveAspectCrop
                          asynchronous: true
                        }
                      }

                      Column {
                        width: parent.width - (root.resultPhoto !== "" ? Style.space(120) + Style.spacing.md : 0)
                        spacing: Style.space(6)

                        Text {
                          width: parent.width
                          text: root.resultCallsign
                          color: root.resultFg
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.display
                          font.bold: true
                          wrapMode: Text.Wrap
                        }

                        Row {
                          spacing: Style.space(8)
                          visible: root.resultCountry !== "" || root.resultFlag !== ""

                          Image {
                            visible: root.resultFlag !== ""
                            source: root.safeQrzUrl(root.resultFlag)
                            width: Style.space(24)
                            height: Style.space(16)
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                          }

                          Text {
                            text: root.resultCountry
                            color: root.resultMuted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                          }
                        }

                        Text {
                          width: parent.width
                          visible: root.resultQsl !== ""
                          text: "QSL: " + root.resultQsl
                          color: root.resultFg
                          wrapMode: Text.Wrap
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                        }

                        Text {
                          width: parent.width
                          visible: root.xmlName !== ""
                          text: root.xmlName
                          color: root.resultFg
                          wrapMode: Text.Wrap
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          font.bold: true
                        }

                        Text {
                          width: parent.width
                          visible: root.xmlEmail !== ""
                          textFormat: Text.RichText
                          text: "<a href=\"mailto:" + root.xmlEmail + "\">" + root.xmlEmail + "</a>"
                          color: root.resultAccent
                          wrapMode: Text.Wrap
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          onLinkActivated: function(link) { root.openSafeUrl(link) }
                        }

                        Text {
                          width: parent.width
                          visible: root.xmlAddress !== ""
                          text: root.xmlAddress
                          color: root.resultFg
                          wrapMode: Text.Wrap
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                        }

                        Text {
                          width: parent.width
                          visible: root.xmlCounty !== "" || root.xmlGrid !== ""
                          text: {
                            var parts = []
                            if (root.xmlCounty) parts.push(root.xmlCounty)
                            if (root.xmlGrid) parts.push("Grid " + root.xmlGrid)
                            return parts.join(" · ")
                          }
                          color: root.resultMuted
                          wrapMode: Text.Wrap
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                        }

                        Text {
                          width: parent.width
                          visible: root.xmlClass !== "" || root.xmlCq !== "" || root.xmlItu !== ""
                          text: {
                            var parts = []
                            if (root.xmlClass) parts.push("Class " + root.xmlClass)
                            if (root.xmlCq) parts.push("CQ " + root.xmlCq)
                            if (root.xmlItu) parts.push("ITU " + root.xmlItu)
                            return parts.join(" · ")
                          }
                          color: root.resultMuted
                          wrapMode: Text.Wrap
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                        }

                        Text {
                          width: parent.width
                          visible: root.xmlQslmgr !== ""
                          text: "QSL mgr: " + root.xmlQslmgr
                          color: root.resultFg
                          wrapMode: Text.Wrap
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                        }

                        Text {
                          width: parent.width
                          visible: root.xmlLotw !== "" || root.xmlEqsl !== "" || root.xmlMqsl !== ""
                          text: {
                            var parts = []
                            if (root.xmlLotw) parts.push("LoTW: " + root.xmlLotw)
                            if (root.xmlEqsl) parts.push("eQSL: " + root.xmlEqsl)
                            if (root.xmlMqsl) parts.push("bureau: " + root.xmlMqsl)
                            return parts.join(" · ")
                          }
                          color: root.resultMuted
                          wrapMode: Text.Wrap
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }

                        Text {
                          visible: root.xmlMapsUrl !== ""
                          text: "Open in Google Maps"
                          color: root.resultAccent
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          font.underline: mapsHover.containsMouse
                          MouseArea {
                            id: mapsHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.openSafeUrl(root.xmlMapsUrl)
                          }
                        }

                        Repeater {
                          model: detailModel
                          Text {
                            width: parent.width
                            text: model.line
                            color: root.resultMuted
                            wrapMode: Text.Wrap
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                          }
                        }

                        Text {
                          width: parent.width
                          visible: root.resultManager !== "" || root.resultLookups !== ""
                          text: {
                            var parts = []
                            if (root.resultManager) parts.push("Managed by " + root.resultManager)
                            if (root.resultLookups) parts.push("Lookups: " + root.resultLookups)
                            return parts.join(" · ")
                          }
                          color: root.resultMuted
                          wrapMode: Text.Wrap
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }

                    Rectangle {
                      width: parent.width
                      height: 1
                      visible: root.resultBio !== ""
                      color: root.resultBorder
                    }

                    Text {
                      width: parent.width
                      visible: root.resultBio !== ""
                      textFormat: Text.RichText
                      wrapMode: Text.Wrap
                      baseUrl: "https://www.qrz.com/"
                      color: root.resultFg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      text: root.styledBio
                      onLinkActivated: function(link) { root.openSafeUrl(link) }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
