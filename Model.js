// No QML imports, so this file runs in a plain JS harness.

var NOISE_OFF = 0
var NOISE_ANC = 1
var NOISE_TRANSPARENCY = 2
var NOISE_ADAPTIVE = 3
var NOISE_UNKNOWN = -1
var LEVEL_UNKNOWN = -1
var LID_OPEN = 0
var LID_CLOSED = 1
var LID_UNKNOWN = 2

var GLYPH_CHECK = "\uDB80\uDD2C"
var MAX_ERROR_CHARS = 140
var MAX_STATUS_CHARS = 32768
var MAX_NAME_CHARS = 80
var MAX_ID_CHARS = 64
var MAX_LABEL_CHARS = 80
var MAX_TOUCH_CONTROLS = 16
var MAX_TOUCH_OPTIONS = 32

function defaultPod() {
  return { level: LEVEL_UNKNOWN, charging: false, inEar: false, inCase: false }
}

function defaultStatus() {
  return {
    ok: false,
    lastError: "",
    connected: false,
    deviceName: "",
    modelName: "",
    modelId: "",
    isHeadset: false,
    isProSeries: false,
    backend: "",
    supportsNoiseOff: false,
    supportsNoiseControl: false,
    supportsAdaptive: false,
    supportsManualAnc: false,
    manualAnc: LEVEL_UNKNOWN,
    manualAncMin: 1,
    manualAncMax: 5,
    adaptiveAnc: LEVEL_UNKNOWN,
    adaptiveNoiseLevel: 0,
    noiseMode: NOISE_UNKNOWN,
    left: defaultPod(),
    right: defaultPod(),
    caseBattery: { level: LEVEL_UNKNOWN, charging: false },
    headset: { level: LEVEL_UNKNOWN, charging: false },
    touchAvailable: false,
    supportsTouchReset: false,
    supportsTouchTone: false,
    touchTone: false,
    touchControls: []
  }
}

function defaultTouch() {
  return {
    available: false,
    reset: false,
    supportsTone: false,
    tone: false,
    controls: []
  }
}

function intOr(value, fallback) {
  var n = parseInt(value, 10)
  return isFinite(n) ? n : fallback
}

function clip(value, limit) {
  var text = String(value == null ? "" : value)
  if (text.length <= limit) return text
  return text.slice(0, limit)
}

function podFrom(raw) {
  var pod = defaultPod()
  if (!raw || typeof raw !== "object") return pod
  if (raw.available !== true) return pod
  pod.level = intOr(raw.level, LEVEL_UNKNOWN)
  pod.charging = raw.charging === true
  pod.inCase = raw.in_case === true || pod.charging
  pod.inEar = raw.in_ear === true && !pod.inCase
  return pod
}

function parseStatus(raw) {
  var status = defaultStatus()
  var text = String(raw || "").trim()
  if (text === "") {
    status.lastError = "The Soundcore status file is empty"
    return status
  }
  if (text.length > MAX_STATUS_CHARS) {
    status.lastError = "The Soundcore status file is too large"
    return status
  }
  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    status.lastError = "Could not read the Soundcore status file"
    return status
  }
  if (!parsed || typeof parsed !== "object" || parsed.schema_version === undefined) {
    status.lastError = "The Soundcore status file carried no schema_version"
    return status
  }
  if (intOr(parsed.schema_version, 0) > 1) {
    status.lastError = "Soundcore status schema " + parsed.schema_version + " is newer than this panel"
    return status
  }
  status.ok = true
  status.connected = parsed.connected === true
  status.deviceName = clip(parsed.device_name || "", MAX_NAME_CHARS)
  status.modelName = clip(parsed.model_name || "", MAX_NAME_CHARS)
  status.modelId = clip(parsed.model_id || "", MAX_ID_CHARS)
  status.isHeadset = parsed.is_headset === true
  status.isProSeries = parsed.is_pro_series === true
  status.backend = clip(parsed.backend || "", MAX_ID_CHARS)
  status.supportsNoiseOff = parsed.supports_noise_off === true
  status.supportsNoiseControl = parsed.supports_noise_control === true
  status.supportsAdaptive = parsed.supports_adaptive === true
  status.supportsManualAnc = parsed.supports_manual_anc === true
  status.manualAnc = intOr(parsed.manual_anc, LEVEL_UNKNOWN)
  status.manualAncMin = intOr(parsed.manual_anc_min, 1)
  status.manualAncMax = intOr(parsed.manual_anc_max, 5)
  if (status.manualAncMin > status.manualAncMax) {
    status.manualAncMin = 1
    status.manualAncMax = 5
  }
  status.adaptiveAnc = intOr(parsed.adaptive_anc, LEVEL_UNKNOWN)
  status.adaptiveNoiseLevel = intOr(parsed.adaptive_noise_level, 0)
  status.noiseMode = intOr(parsed.noise_mode, NOISE_UNKNOWN)
  status.left = podFrom(parsed.left)
  status.right = podFrom(parsed.right)
  status.caseBattery = {
    level: parsed.case && parsed.case.available === true ? intOr(parsed.case.level, LEVEL_UNKNOWN) : LEVEL_UNKNOWN,
    charging: !!(parsed.case && parsed.case.charging)
  }
  status.headset = {
    level: parsed.headset && parsed.headset.available === true ? intOr(parsed.headset.level, LEVEL_UNKNOWN) : LEVEL_UNKNOWN,
    charging: !!(parsed.headset && parsed.headset.charging)
  }
  var touch = parseTouch(parsed.touch)
  status.touchAvailable = touch.available
  status.supportsTouchReset = touch.reset
  status.supportsTouchTone = touch.supportsTone
  status.touchTone = touch.tone
  status.touchControls = touch.controls
  return status
}

function parseTouch(raw) {
  var out = defaultTouch()
  if (!raw || typeof raw !== "object") return out
  out.available = raw.available === true
  out.reset = raw.reset === true
  out.supportsTone = raw.supports_tone === true
  out.tone = raw.tone === true
  var list = raw.controls
  if (!list || typeof list.length !== "number") return out
  var count = Math.min(list.length, MAX_TOUCH_CONTROLS)
  for (var i = 0; i < count; i++) {
    var row = list[i]
    if (!row || !row.id) continue
    var options = []
    var rawOpts = row.options
    if (rawOpts && rawOpts.length) {
      var optCount = Math.min(rawOpts.length, MAX_TOUCH_OPTIONS)
      for (var j = 0; j < optCount; j++) {
        var opt = rawOpts[j]
        if (!opt) continue
        options.push({
          id: clip(opt.id == null ? "" : opt.id, MAX_ID_CHARS),
          label: clip(opt.label || opt.id || "Off", MAX_LABEL_CHARS)
        })
      }
    }
    out.controls.push({
      id: clip(row.id, MAX_ID_CHARS),
      label: clip(row.label || row.id, MAX_LABEL_CHARS),
      value: clip(row.value == null ? "" : row.value, MAX_ID_CHARS),
      options: options
    })
  }
  if (out.controls.length) out.available = true
  return out
}

function touchValueById(controls, id) {
  if (!controls) return ""
  for (var i = 0; i < controls.length; i++) {
    if (controls[i].id === id) return String(controls[i].value || "")
  }
  return ""
}

function withTouchValue(controls, id, value) {
  var next = []
  if (!controls) return next
  for (var i = 0; i < controls.length; i++) {
    var row = controls[i]
    if (row.id === id)
      next.push({ id: row.id, label: row.label, value: String(value || ""), options: row.options })
    else
      next.push(row)
  }
  return next
}

function touchValueLabel(control) {
  if (!control) return ""
  var val = String(control.value || "")
  var opts = control.options || []
  for (var i = 0; i < opts.length; i++) {
    if (String(opts[i].id || "") === val) return opts[i].label
  }
  return val === "" ? "Off" : val
}

function nextTouchValue(control, dir) {
  var opts = (control && control.options) || []
  if (opts.length === 0) return ""
  var val = String(control.value || "")
  var at = 0
  for (var i = 0; i < opts.length; i++) {
    if (String(opts[i].id || "") === val) { at = i; break }
  }
  var n = opts.length
  var step = dir < 0 ? n - 1 : 1
  return String(opts[(at + step) % n].id || "")
}

function availableModes(supportsControl, supportsOff, supportsAdaptive) {
  if (!supportsControl) return []
  var modes = []
  if (supportsOff) modes.push(NOISE_OFF)
  modes.push(NOISE_TRANSPARENCY)
  if (supportsAdaptive) modes.push(NOISE_ADAPTIVE)
  modes.push(NOISE_ANC)
  return modes
}

function noiseModeName(mode) {
  if (mode === NOISE_OFF) return "Off"
  if (mode === NOISE_ANC) return "Noise Cancellation"
  if (mode === NOISE_TRANSPARENCY) return "Transparency"
  if (mode === NOISE_ADAPTIVE) return "Adaptive"
  return "Unknown"
}

function noiseModeKey(mode) {
  if (mode === NOISE_OFF) return "off"
  if (mode === NOISE_ANC) return "anc"
  if (mode === NOISE_TRANSPARENCY) return "transparency"
  if (mode === NOISE_ADAPTIVE) return "adaptive"
  return ""
}

function levelFraction(level) {
  if (level === LEVEL_UNKNOWN) return 0
  return Math.max(0, Math.min(1, level / 100))
}

function levelText(level) {
  return level === LEVEL_UNKNOWN ? "--" : String(level) + "%"
}

function podMeta(pod) {
  if (!pod || pod.level === LEVEL_UNKNOWN) return ""
  if (pod.charging) return "Charging"
  if (pod.inCase) return "In case"
  if (pod.inEar) return "In ear"
  return ""
}

function wearingText(left, right) {
  var l = left && left.inEar
  var r = right && right.inEar
  if (l && r) return "Both buds in"
  if (l) return "Left bud in"
  if (r) return "Right bud in"
  return "Neither bud in"
}

function elideError(value) {
  var text = String(value || "").replace(/\s+/g, " ").trim()
  if (text.length <= MAX_ERROR_CHARS) return text
  return text.slice(0, MAX_ERROR_CHARS - 3) + "..."
}

function showHeadsetIcon(iconSetting, isHeadset) {
  var icon = String(iconSetting || "Auto")
  if (icon === "Over-ear") return true
  if (icon === "Earbuds") return false
  return isHeadset === true
}

// Same three marks omapods uses. In-ear Soundcore (P40i, Liberty) take the
// Pro silhouette; over-ear takes Max; Auto follows the connected device.
function iconVariant(iconSetting, isHeadset) {
  return showHeadsetIcon(iconSetting, isHeadset) ? "max" : "pro"
}

function normalizeName(value) {
  return String(value || "").toLowerCase().replace(/soundcore/g, " ").replace(/[^a-z0-9]+/g, " ").trim()
}

function modelAliases(displayName) {
  var aliases = []
  var parts = String(displayName || "").split("/")
  for (var i = 0; i < parts.length; i++) {
    var raw = parts[i].trim()
    if (!raw) continue
    aliases.push(raw)
    var stripped = raw.replace(/^Soundcore\s+/i, "").trim()
    if (stripped && stripped !== raw) aliases.push(stripped)
  }
  return aliases
}

function matchScore(deviceName, modelName) {
  var device = normalizeName(deviceName)
  if (!device) return 0
  var aliases = modelAliases(modelName)
  var best = 0
  for (var i = 0; i < aliases.length; i++) {
    var alias = normalizeName(aliases[i])
    if (!alias) continue
    if (device === alias) return 1000 + alias.length
    if (device.indexOf(alias) >= 0 || alias.indexOf(device) >= 0)
      best = Math.max(best, alias.length)
  }
  return best
}
