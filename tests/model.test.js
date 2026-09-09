// Run with: deno run --allow-read tests/model.test.js

const source = Deno.readTextFileSync(new URL("../Model.js", import.meta.url))
const Model = new Function(
  source + "; return { parseStatus, podFrom, defaultPod, availableModes, noiseModeName, noiseModeKey, levelFraction, levelText, podMeta, elideError, matchScore, modelAliases, normalizeName, showHeadsetIcon, iconVariant, parseTouch, nextTouchValue, touchValueLabel, withTouchValue, touchValueById, NOISE_OFF, NOISE_ANC, NOISE_TRANSPARENCY, NOISE_ADAPTIVE, LEVEL_UNKNOWN, NOISE_UNKNOWN }"
)()

let failures = 0

function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected)
  if (!ok) {
    failures++
    console.log("FAIL " + name + "\n  expected " + JSON.stringify(expected) + "\n  got      " + JSON.stringify(actual))
  }
}

const live = '{"schema_version":1,"connected":true,"device_name":"soundcore P40i","model_name":"Soundcore P40i","model_id":"SoundcoreA3955","is_headset":false,"supports_noise_off":true,"supports_noise_control":true,"supports_adaptive":true,"supports_manual_anc":true,"manual_anc":3,"manual_anc_min":1,"manual_anc_max":5,"noise_mode":1,"left":{"available":true,"charging":false,"in_case":false,"in_ear":true,"level":80},"right":{"available":true,"charging":false,"in_case":true,"in_ear":false,"level":80},"case":{"available":true,"charging":false,"level":100},"headset":{"available":false,"charging":false,"level":0}}'
const good = Model.parseStatus(live)
check("live line parses", good.ok, true)
check("live modelName", good.modelName, "Soundcore P40i")
check("live left level", good.left.level, 80)
check("live left in ear", good.left.inEar, true)
check("live right in case", good.right.inCase, true)
check("live noiseMode", good.noiseMode, 1)
check("live supportsAdaptive", good.supportsAdaptive, true)
check("live supportsManualAnc", good.supportsManualAnc, true)
check("live manualAnc", good.manualAnc, 3)

const empty = Model.parseStatus("")
check("empty input is not ok", empty.ok, false)

const garbage = Model.parseStatus("not json")
check("garbage is not ok", garbage.ok, false)

const noVersion = Model.parseStatus('{"connected":true}')
check("missing schema is not ok", noVersion.ok, false)

const gone = Model.podFrom({ available: false, level: 82, charging: true, in_ear: true })
check("unavailable pod reports no level", gone.level, Model.LEVEL_UNKNOWN)

check("P40i modes include off and adaptive", Model.availableModes(true, true, true), [0, 2, 3, 1])
check("a device without Normal has no Off", Model.availableModes(true, false, true), [2, 3, 1])
check("no control means no modes", Model.availableModes(false, true, true), [])

check("noise key for adaptive", Model.noiseModeKey(3), "adaptive")
check("unknown level draws dashes", Model.levelText(Model.LEVEL_UNKNOWN), "--")

check("exact P40i match beats a short alias", Model.matchScore("soundcore P40i", "Soundcore P40i") > Model.matchScore("soundcore P40i", "Soundcore P20i / P25i / R50i"), true)
check("Q30 matches Life Q30", Model.matchScore("Soundcore Life Q30", "Soundcore Q30 / Life Q30") > 0, true)
check("AirPods do not match P40i", Model.matchScore("Alex's AirPods Pro", "Soundcore P40i"), 0)
check("Liberty 4 NC does not steal P40i", Model.matchScore("soundcore P40i", "Soundcore Liberty 4 NC"), 0)

check("auto icon follows a headset", Model.showHeadsetIcon("Auto", true), true)
check("auto icon follows buds", Model.showHeadsetIcon("Auto", false), false)
check("earbuds setting wins over a headset", Model.showHeadsetIcon("Earbuds", true), false)
check("over-ear setting wins over buds", Model.showHeadsetIcon("Over-ear", false), true)
check("P40i uses the Pro silhouette", Model.iconVariant("Auto", false), "pro")
check("a headset uses the Max silhouette", Model.iconVariant("Auto", true), "max")
check("in ear meta", Model.podMeta({ level: 80, charging: false, inEar: true, inCase: false }), "In ear")
check("in case meta", Model.podMeta({ level: 80, charging: false, inEar: false, inCase: true }), "In case")
check("charging wins over in ear", Model.podMeta({ level: 80, charging: true, inEar: true, inCase: false }), "Charging")

const touch = Model.parseTouch({
  available: true,
  reset: true,
  supports_tone: true,
  tone: false,
  controls: [{
    id: "leftDoublePress",
    label: "Left double",
    value: "NextSong",
    options: [
      { id: "", label: "Off" },
      { id: "NextSong", label: "Next Song" },
      { id: "PlayPause", label: "Play Pause" }
    ]
  }]
})
check("touch available", touch.available, true)
check("touch value label", Model.touchValueLabel(touch.controls[0]), "Next Song")
check("touch cycles forward", Model.nextTouchValue(touch.controls[0], 1), "PlayPause")
check("touch cycles from last to off", Model.nextTouchValue({ value: "PlayPause", options: touch.controls[0].options }, 1), "")
check("unset press is Off", Model.touchValueLabel({ value: "", options: touch.controls[0].options }), "Off")

const huge = "x".repeat(40000)
check("oversized status is rejected", Model.parseStatus('{"schema_version":1,"device_name":"' + huge + '"}').ok, false)

const longName = Model.parseStatus('{"schema_version":1,"connected":true,"device_name":"' + "n".repeat(200) + '"}')
check("device names are capped", longName.deviceName.length, 80)

const many = []
for (let i = 0; i < 40; i++) many.push({ id: "c" + i, label: "L" + i, value: "", options: [{ id: "a", label: "A" }] })
const cappedTouch = Model.parseTouch({ available: true, controls: many })
check("touch controls are capped", cappedTouch.controls.length, 16)

if (failures) {
  console.log(failures + " failed")
  Deno.exit(1)
}
console.log("ok")
