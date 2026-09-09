import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  property bool daemonReachable: false
  property bool connected: false
  property string deviceName: ""
  property string modelName: ""
  property bool isHeadset: false
  property bool isProSeries: false
  property string backend: ""
  property bool supportsNoiseOff: false
  property bool supportsNoiseControl: false
  property bool supportsAdaptive: false
  property bool supportsManualAnc: false
  property int noiseMode: Model.NOISE_UNKNOWN
  property int manualAnc: Model.LEVEL_UNKNOWN
  property int manualAncMin: 1
  property int manualAncMax: 5
  property int adaptiveAnc: Model.LEVEL_UNKNOWN
  property int adaptiveNoiseLevel: 0
  property var leftPod: Model.defaultPod()
  property var rightPod: Model.defaultPod()
  property var caseBattery: ({ level: Model.LEVEL_UNKNOWN, charging: false })
  property var headsetBattery: ({ level: Model.LEVEL_UNKNOWN, charging: false })
  property var touchControls: []
  property bool touchAvailable: false
  property bool supportsTouchReset: false
  property bool supportsTouchTone: false
  property bool touchTone: false
  property string lastError: ""
  property string actionStatus: ""
  property string findingSide: ""

  readonly property bool hideWhenDisconnected: setting("hideWhenDisconnected", true) === true
  readonly property bool hasDevice: connected
  readonly property bool finding: findingSide !== ""
  readonly property bool hasBattery: daemonReachable
    && (isHeadset
      ? headsetBattery.level !== Model.LEVEL_UNKNOWN
      : (leftPod.level !== Model.LEVEL_UNKNOWN
        || rightPod.level !== Model.LEVEL_UNKNOWN
        || caseBattery.level !== Model.LEVEL_UNKNOWN))
  readonly property bool busy: commandProcess.running
  readonly property int settleHoldMs: 4000
  readonly property int actionStatusMs: 2200
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
    || Quickshell.env("HOME") + "/.local/state")
  readonly property string statePath: stateDir + "/better-omapods/status.json"
  readonly property string pluginDir: {
    var path = Qt.resolvedUrl(".").toString()
    if (path.indexOf("file://") === 0) path = path.slice(7)
    if (path.length > 1 && path.charAt(path.length - 1) === "/")
      path = path.slice(0, path.length - 1)
    return path
  }
  readonly property string bridge: pluginDir + "/bridge.py"
  readonly property string findScript: pluginDir + "/find.sh"

  property string _pendingField: ""
  property var _pendingValue: null
  property var _queued: null
  property string _queuedFind: ""
  property bool _statusReload: false

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function refresh() {
    if (statusProcess.running) {
      _statusReload = true
      return
    }
    statusProcess.command = ["python3", bridge, "read-status"]
    statusProcess.running = true
  }

  function applyLine(raw) {
    var status = Model.parseStatus(raw)
    if (!status.ok) {
      daemonReachable = false
      connected = false
      lastError = status.lastError
      return
    }
    daemonReachable = true
    lastError = ""
    connected = status.connected
    if (!status.connected) return
    deviceName = status.deviceName
    modelName = status.modelName
    isHeadset = status.isHeadset
    isProSeries = status.isProSeries
    backend = status.backend
    supportsNoiseOff = status.supportsNoiseOff
    supportsNoiseControl = status.supportsNoiseControl
    supportsAdaptive = status.supportsAdaptive
    supportsManualAnc = status.supportsManualAnc
    leftPod = status.left
    rightPod = status.right
    caseBattery = status.caseBattery
    headsetBattery = status.headset
    adaptiveAnc = status.adaptiveAnc
    adaptiveNoiseLevel = _settle("adaptiveNoiseLevel", status.adaptiveNoiseLevel)
    manualAncMin = status.manualAncMin
    manualAncMax = status.manualAncMax
    noiseMode = _settle("noiseMode", status.noiseMode)
    manualAnc = _settle("manualAnc", status.manualAnc)
    supportsTouchReset = status.supportsTouchReset
    supportsTouchTone = status.supportsTouchTone
    touchAvailable = status.touchAvailable
    touchTone = _settle("touchTone", status.touchTone)
    if (_pendingField && _pendingField.indexOf("touch:") === 0) {
      var tid = _pendingField.substring(6)
      var reported = Model.touchValueById(status.touchControls, tid)
      if (reported === _pendingValue) {
        _clearPending()
        touchControls = status.touchControls
      } else {
        touchControls = Model.withTouchValue(status.touchControls, tid, _pendingValue)
      }
    } else {
      touchControls = status.touchControls
    }
  }

  function stateGone() {
    daemonReachable = false
    connected = false
    lastError = ""
  }

  function _settle(field, reported) {
    if (_pendingField !== field) return reported
    if (reported === _pendingValue) {
      _clearPending()
      return reported
    }
    return _pendingValue
  }

  function _clearPending() {
    _pendingField = ""
    _pendingValue = null
    settleTimer.stop()
  }

  function availableModes() {
    return Model.availableModes(supportsNoiseControl, supportsNoiseOff, supportsAdaptive)
  }

  function setNoiseMode(mode) {
    if (availableModes().indexOf(mode) < 0) return
    var which = Model.noiseModeKey(mode)
    if (!which) return
    _pendingField = "noiseMode"
    _pendingValue = mode
    root.noiseMode = mode
    settleTimer.restart()
    _sendSet([which])
  }

  function setManualAnc(level) {
    if (!supportsManualAnc) return
    var lo = manualAncMin
    var hi = manualAncMax
    var n = Math.max(lo, Math.min(hi, Math.round(level)))
    if (n === manualAnc && noiseMode === Model.NOISE_ANC && !commandProcess.running) return
    _pendingField = "manualAnc"
    _pendingValue = n
    root.manualAnc = n
    if (availableModes().indexOf(Model.NOISE_ANC) >= 0)
      root.noiseMode = Model.NOISE_ANC
    settleTimer.restart()
    _sendSet(["anc-level", String(n)])
  }

  function setAdaptiveNoiseLevel(level) {
    if (!supportsAdaptive) return
    var n = Math.max(0, Math.min(100, Math.round(level)))
    _pendingField = "adaptiveNoiseLevel"
    _pendingValue = n
    root.adaptiveNoiseLevel = n
    settleTimer.restart()
    _sendSet(["adaptive-level", String(n)])
  }

  function setTouch(id, value) {
    if (!touchAvailable) return
    var next = String(value || "")
    _pendingField = "touch:" + id
    _pendingValue = next
    touchControls = Model.withTouchValue(touchControls, id, next)
    settleTimer.restart()
    _sendSet(["touch", id, next])
  }

  function cycleTouch(id, dir) {
    if (!touchAvailable) return
    var controls = touchControls
    for (var i = 0; i < controls.length; i++) {
      if (controls[i].id === id) {
        setTouch(id, Model.nextTouchValue(controls[i], dir || 1))
        return
      }
    }
  }

  function resetTouch() {
    if (!supportsTouchReset) return
    _sendSet(["touch-reset"])
  }

  function setTouchTone(on) {
    if (!supportsTouchTone) return
    var next = !!on
    _pendingField = "touchTone"
    _pendingValue = next
    touchTone = next
    settleTimer.restart()
    _sendSet(["touch-tone", next ? "true" : "false"])
  }

  function _sendSet(args) {
    if (commandProcess.running) {
      _queued = args
      return
    }
    commandProcess.command = ["python3", bridge, "set"].concat(args)
    commandProcess.running = true
  }

  function cycleNoiseMode() {
    if (!hasDevice) return
    var modes = availableModes()
    if (modes.length === 0) return
    var at = modes.indexOf(noiseMode)
    setNoiseMode(at < 0 ? modes[0] : modes[(at + 1) % modes.length])
  }

  function find(side) {
    if (side !== "left" && side !== "right" && side !== "both") return
    if (!hasDevice) return
    if (findProcess.running) {
      _queuedFind = side
      stopFind()
      return
    }
    findingSide = side
    findProcess.command = ["bash", findScript, side]
    findProcess.running = true
  }

  function stopFind() {
    if (!finding && !findProcess.running) return
    if (_queuedFind)
      stopProcess.command = ["bash", findScript, "stop", "--hold"]
    else
      stopProcess.command = ["bash", findScript, "stop"]
    stopProcess.running = true
  }

  Timer {
    id: settleTimer
    interval: root.settleHoldMs
    repeat: false
    onTriggered: { root._clearPending(); root.refresh() }
  }

  Timer {
    id: actionStatusTimer
    interval: root.actionStatusMs
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
    onLoaded: root.refresh()
    onLoadFailed: root.stateGone()
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode === 0) root.applyLine(statusOut.text)
      else root.stateGone()
      if (root._statusReload) {
        root._statusReload = false
        root.refresh()
      }
    }
  }

  Process {
    id: commandProcess
    running: false
    command: []
    stderr: StdioCollector { id: commandErr; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root._clearPending()
        root.refresh()
        root.actionStatus = Model.elideError(commandErr.text || "Could not change listening mode")
        actionStatusTimer.restart()
      } else {
        root.refresh()
      }
      if (root._queued) {
        var next = root._queued
        root._queued = null
        root._sendSet(next)
      }
    }
  }

  Process {
    id: findProcess
    running: false
    command: []
    stderr: StdioCollector { id: findErr; waitForEnd: true }
    onExited: function (exitCode) {
      root.findingSide = ""
      if (exitCode !== 0 && !root._queuedFind) {
        root.actionStatus = Model.elideError(findErr.text || "Could not play a locating tone")
        actionStatusTimer.restart()
      }
      if (root._queuedFind) {
        var next = root._queuedFind
        root._queuedFind = ""
        root.find(next)
      }
    }
  }

  Process {
    id: stopProcess
    running: false
    command: []
  }
}
