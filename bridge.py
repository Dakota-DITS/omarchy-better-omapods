#!/usr/bin/env python3
"""Publish battery and listening mode for any connected OpenSCQ30 device.

OpenSCQ30 covers Soundcore's ANC earbuds and headphones (P40i, Liberty, Space,
Q30, and the rest of `openscq30 list-models`). The panel never talks to BlueZ
itself: this process writes $XDG_STATE_HOME/better-omapods/status.json and applies
mode changes through `set`.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path

OPENSCQ30 = os.environ.get("OPENSCQ30", os.path.expanduser("~/.local/bin/openscq30"))
if not os.path.isfile(OPENSCQ30):
    OPENSCQ30 = "openscq30"

LIBREPODS_CTL = os.environ.get("LIBREPODS_CTL", os.path.expanduser("~/.local/bin/librepods-ctl"))
if not os.path.isfile(LIBREPODS_CTL):
    LIBREPODS_CTL = "librepods-ctl"

STATE_HOME = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
LIBREPODS_STATUS = STATE_HOME / "librepods" / "status.json"
STATE_DIR = STATE_HOME / "better-omapods"
STATE_PATH = STATE_DIR / "status.json"
LOCK_PATH = STATE_DIR / "openscq30.lock"
POLL_CONNECTED = 3
POLL_IDLE = 5

NOISE_OFF = 0
NOISE_ANC = 1
NOISE_TRANSPARENCY = 2
NOISE_ADAPTIVE = 3

GET_IDS = [
    "ambientSoundMode",
    "noiseCancelingMode",
    "adaptiveNoiseCanceling",
    "manualNoiseCanceling",
    "batteryLevelLeft",
    "batteryLevelRight",
    "caseBatteryLevel",
    "isChargingLeft",
    "isChargingRight",
    "twsStatus",
    "hostDevice",
    "touchTone",
    "leftSinglePress",
    "rightSinglePress",
    "leftDoublePress",
    "rightDoublePress",
    "leftTriplePress",
    "rightTriplePress",
    "leftLongPress",
    "rightLongPress",
]

TOUCH_IDS = [
    "leftSinglePress",
    "rightSinglePress",
    "leftDoublePress",
    "rightDoublePress",
    "leftTriplePress",
    "rightTriplePress",
    "leftLongPress",
    "rightLongPress",
]

TOUCH_LABELS = {
    "leftSinglePress": "Left single",
    "rightSinglePress": "Right single",
    "leftDoublePress": "Left double",
    "rightDoublePress": "Right double",
    "leftTriplePress": "Left triple",
    "rightTriplePress": "Right triple",
    "leftLongPress": "Left hold",
    "rightLongPress": "Right hold",
}


def run(cmd, timeout=25):
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except FileNotFoundError as exc:
        return subprocess.CompletedProcess(cmd, 1, "", str(exc))
    try:
        out, err = proc.communicate(timeout=timeout)
        return subprocess.CompletedProcess(cmd, proc.returncode, out, err)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try:
            out, err = proc.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            out, err = proc.communicate()
        return subprocess.CompletedProcess(cmd, 1, out or "", (err or "") + "timeout")


@contextmanager
def openscq30_lock():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    fd = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def uuid_busy(proc):
    text = f"{proc.stderr or ''}{proc.stdout or ''}".lower()
    return any(
        needle in text
        for needle in ("uuid already registered", "connect timed out", "connection reset")
    )


def normalize_name(value):
    text = re.sub(r"soundcore", " ", str(value or ""), flags=re.I)
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def model_aliases(display_name):
    aliases = []
    for part in str(display_name or "").split("/"):
        raw = part.strip()
        if not raw:
            continue
        aliases.append(raw)
        stripped = re.sub(r"^Soundcore\s+", "", raw, flags=re.I).strip()
        if stripped and stripped != raw:
            aliases.append(stripped)
    return aliases


def match_score(device_name, model_name):
    device = normalize_name(device_name)
    if not device:
        return 0
    best = 0
    for alias in model_aliases(model_name):
        alias_n = normalize_name(alias)
        if not alias_n:
            continue
        if device == alias_n:
            return 1000 + len(alias_n)
        if alias_n in device or device in alias_n:
            best = max(best, len(alias_n))
    return best


def parse_models(text):
    models = []
    for line in (text or "").splitlines()[1:]:
        line = line.strip()
        if not line or line.lower().startswith("soundcoredevelopment"):
            continue
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        model_id, name = parts[0], parts[1].strip()
        if not model_id.startswith("Soundcore"):
            continue
        models.append({"id": model_id, "name": name})
    return models


def load_models():
    proc = run([OPENSCQ30, "list-models"], timeout=8)
    return parse_models(proc.stdout if proc.returncode == 0 else "")


def bluetooth_devices():
    proc = run(["bluetoothctl", "devices"], timeout=5)
    devices = []
    for line in (proc.stdout or "").splitlines():
        parts = line.split(None, 2)
        if len(parts) >= 3 and parts[0] == "Device":
            devices.append({"mac": parts[1], "name": parts[2]})
    return devices


def is_connected(mac):
    if not mac:
        return False
    path = "/org/bluez/hci0/dev_" + mac.replace(":", "_")
    proc = run(
        ["busctl", "get-property", "org.bluez", path, "org.bluez.Device1", "Connected"],
        timeout=4,
    )
    return "true" in (proc.stdout or "").lower()


def bluez_battery(mac):
    path = "/org/bluez/hci0/dev_" + mac.replace(":", "_")
    proc = run(
        ["busctl", "get-property", "org.bluez", path, "org.bluez.Battery1", "Percentage"],
        timeout=4,
    )
    m = re.search(r"\b(\d+)\b", proc.stdout or "")
    return int(m.group(1)) if m else -1


def pick_device(models, devices):
    best = None
    best_score = 0
    for device in devices:
        if not is_connected(device["mac"]):
            continue
        for model in models:
            score = match_score(device["name"], model["name"])
            if score > best_score:
                best_score = score
                best = {
                    "mac": device["mac"],
                    "bt_name": device["name"],
                    "id": model["id"],
                    "name": model["name"],
                }
    return best if best_score > 0 else None


def looks_apple(name):
    return bool(re.search(r"airpods|\bbeats\b", str(name or ""), re.I))


def looks_headset(name):
    return bool(
        re.search(
            r"headphone|headset|\bmax\b|wh-?\d|wf-1000|\bxm[2-6]\b|\bqc\b|quietcomfort",
            str(name or ""),
            re.I,
        )
    )


def a2dp_running_mac():
    proc = run(["pactl", "list", "short", "sinks"], timeout=4)
    for line in (proc.stdout or "").splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[1]
        state = parts[-1] if len(parts) > 2 else ""
        if name.startswith("bluez_output.") and state == "RUNNING":
            hexpart = name.split(".")[1]
            return hexpart.replace("_", ":").upper()
    return ""


def has_audio_sink(mac):
    if not mac:
        return False
    tag = mac.replace(":", "_")
    proc = run(["pactl", "list", "short", "sinks"], timeout=4)
    return f"bluez_output.{tag}" in (proc.stdout or "")


def librepods_live():
    try:
        data = json.loads(LIBREPODS_STATUS.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict) or data.get("connected") is not True:
        return None
    return data


def soundcore_for(device, models):
    best = None
    best_score = 0
    for model in models:
        score = match_score(device.get("name"), model["name"])
        if score > best_score:
            best_score = score
            best = model
    return best if best_score > 0 else None


def empty_touch():
    return {
        "available": False,
        "reset": False,
        "supports_tone": False,
        "tone": False,
        "controls": [],
    }


def pick_target(models, devices):
    connected = [d for d in devices if is_connected(d["mac"])]
    running = a2dp_running_mac()
    apple = librepods_live()
    ranked = []
    for device in connected:
        sc = soundcore_for(device, models)
        extra = {}
        if sc:
            backend = "openscq30"
            kind = 300
            extra = {"id": sc["id"], "name": sc["name"]}
        elif looks_apple(device["name"]):
            backend = "librepods"
            kind = 200
        elif has_audio_sink(device["mac"]) or bluez_battery(device["mac"]) >= 0:
            backend = "bluez"
            kind = 100
        else:
            continue
        bonus = 1000 if running and device["mac"].replace(":", "").upper() == running.replace(":", "").upper() else 0
        ranked.append(
            (
                bonus + kind,
                {
                    "mac": device["mac"],
                    "bt_name": device["name"],
                    "backend": backend,
                    **extra,
                },
            )
        )
    if apple and not any(item[1]["backend"] == "librepods" for item in ranked):
        ranked.append(
            (
                200,
                {
                    "mac": "",
                    "bt_name": apple.get("device_name") or apple.get("model_name") or "AirPods",
                    "backend": "librepods",
                },
            )
        )
    if not ranked:
        return None
    ranked.sort(key=lambda row: -row[0])
    return ranked[0][1]


def status_from_librepods(target):
    raw = librepods_live()
    if not raw:
        return disconnected_status()
    left_raw = raw.get("left") or {}
    right_raw = raw.get("right") or {}
    case_raw = raw.get("case") or {}
    headset_raw = raw.get("headset") or {}
    is_headset = raw.get("is_headset") is True
    left_level = int(left_raw["level"]) if left_raw.get("available") else -1
    right_level = int(right_raw["level"]) if right_raw.get("available") else -1
    case_level = int(case_raw["level"]) if case_raw.get("available") else -1
    headset_level = int(headset_raw["level"]) if headset_raw.get("available") else -1
    left_chg = bool(left_raw.get("charging"))
    right_chg = bool(right_raw.get("charging"))
    status = disconnected_status()
    status.update(
        {
            "connected": True,
            "backend": "librepods",
            "mac": target.get("mac") or "",
            "device_name": raw.get("device_name") or target.get("bt_name") or "",
            "model_name": raw.get("model_name") or "",
            "model_id": str(raw.get("model_number") or ""),
            "is_headset": is_headset,
            "is_pro_series": raw.get("is_pro_series") is True,
            "supports_noise_off": raw.get("supports_noise_off") is not False,
            "supports_noise_control": raw.get("supports_noise_control") is not False,
            "supports_adaptive": raw.get("supports_adaptive") is True,
            "supports_manual_anc": False,
            "noise_mode": int(raw.get("noise_mode") if raw.get("noise_mode") is not None else -1),
            "adaptive_noise_level": int(raw.get("adaptive_noise_level") or 0),
            "left": pod(
                left_level,
                left_chg,
                bool(left_raw.get("in_ear")) and not left_chg,
                left_chg,
            ),
            "right": pod(
                right_level,
                right_chg,
                bool(right_raw.get("in_ear")) and not right_chg,
                right_chg,
            ),
            "case": pod(case_level, bool(case_raw.get("charging"))),
            "headset": pod(headset_level, bool(headset_raw.get("charging")))
            if is_headset
            else pod(-1, False),
            "touch": empty_touch(),
        }
    )
    return status


def status_from_bluez(target):
    level = bluez_battery(target.get("mac"))
    name = target.get("bt_name") or "Bluetooth headphones"
    status = disconnected_status()
    status.update(
        {
            "connected": True,
            "backend": "bluez",
            "mac": target.get("mac") or "",
            "device_name": name,
            "model_name": name,
            "is_headset": True,
            "supports_noise_control": False,
            "headset": pod(level, False) if level >= 0 else pod(-1, False),
            "touch": empty_touch(),
        }
    )
    return status


def openscq30_device(mac, args, timeout=22, retries=1):
    cmd = [OPENSCQ30, "device", "--mac-address", mac, *args]
    last = None
    for attempt in range(max(1, retries)):
        last = run(cmd, timeout=timeout)
        if last.returncode == 0:
            return last
        if uuid_busy(last) and attempt + 1 < retries:
            time.sleep(0.8 * (attempt + 1))
            continue
        return last
    return last


def setting_map(rows):
    out = {}
    for row in rows or []:
        val = (row.get("value") or {}).get("value")
        out[row.get("settingId")] = val
    return out


def list_setting_ids(mac):
    proc = openscq30_device(mac, ["list-settings", "--json", "--no-categories"], timeout=18, retries=1)
    if proc.returncode != 0:
        return {}
    try:
        data = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        return {}
    if isinstance(data, dict):
        return data
    return {}


def query_settings(mac, setting_ids):
    wanted = [sid for sid in GET_IDS if sid in setting_ids]
    if not wanted:
        return {}
    args = ["setting", "--json"]
    for sid in wanted:
        args.extend(["--get", sid])
    proc = openscq30_device(mac, args, timeout=18, retries=1)
    if proc.returncode != 0:
        return None
    try:
        return setting_map(json.loads(proc.stdout or "[]"))
    except json.JSONDecodeError:
        return None


def fifths(value):
    text = str(value or "")
    if "/" in text:
        num, den = text.split("/", 1)
        try:
            n, d = int(num), int(den)
            return int(round(100 * n / d)) if d > 0 else -1
        except ValueError:
            return -1
    try:
        n = int(text)
        return n if 0 <= n <= 100 else -1
    except ValueError:
        return -1


def yes(value):
    return str(value).strip().lower() in ("yes", "true", "1", "charging")


def select_options(setting_ids, setting_id):
    spec = setting_ids.get(setting_id) or {}
    setting = spec.get("setting") or {}
    return [str(item) for item in (setting.get("options") or [])]


def humanize_id(value):
    text = re.sub(r"([a-z])([A-Z])", r"\1 \2", str(value or ""))
    return text.replace("_", " ").strip() or "Off"


def touch_options(setting_ids, setting_id):
    spec = setting_ids.get(setting_id) or {}
    setting = spec.get("setting") or {}
    options = [str(item) for item in (setting.get("options") or [])]
    labels = [str(item) for item in (setting.get("localizedOptions") or [])]
    rows = [{"id": "", "label": "Off"}]
    for i, oid in enumerate(options):
        label = labels[i] if i < len(labels) and labels[i] else humanize_id(oid)
        rows.append({"id": oid, "label": label})
    return rows


def touch_payload(setting_ids, settings, caps):
    controls = []
    for sid in TOUCH_IDS:
        if sid not in setting_ids:
            continue
        raw = settings.get(sid)
        value = "" if raw is None else str(raw)
        controls.append(
            {
                "id": sid,
                "label": TOUCH_LABELS.get(sid, humanize_id(sid)),
                "value": value,
                "options": touch_options(setting_ids, sid),
            }
        )
    return {
        "available": bool(controls),
        "reset": bool(caps.get("supports_touch_reset")),
        "supports_tone": bool(caps.get("supports_touch_tone")),
        "tone": yes(settings.get("touchTone")) if caps.get("supports_touch_tone") else False,
        "controls": controls,
    }


def int_setting(value, fallback=-1):
    text = str(value or "").strip()
    if "/" in text:
        text = text.split("/", 1)[0]
    try:
        return int(text)
    except ValueError:
        return fallback


def range_bounds(setting_ids, setting_id, default_start=1, default_end=5):
    spec = (setting_ids.get(setting_id) or {}).get("setting") or {}
    try:
        start = int(spec.get("start", default_start))
        end = int(spec.get("end", default_end))
    except (TypeError, ValueError):
        return default_start, default_end
    if end < start:
        return default_start, default_end
    return start, end


def capabilities(setting_ids):
    ambient = select_options(setting_ids, "ambientSoundMode")
    cancel = select_options(setting_ids, "noiseCancelingMode")
    has_ambient = "ambientSoundMode" in setting_ids
    anc_min, anc_max = range_bounds(setting_ids, "manualNoiseCanceling")
    return {
        "supports_noise_control": has_ambient and bool(ambient),
        "supports_noise_off": "Normal" in ambient,
        "supports_transparency": "Transparency" in ambient,
        "supports_anc": "NoiseCanceling" in ambient,
        "supports_adaptive": "Adaptive" in cancel,
        "supports_manual_anc": "manualNoiseCanceling" in setting_ids,
        "manual_anc_min": anc_min,
        "manual_anc_max": anc_max,
        "supports_touch": any(sid in setting_ids for sid in TOUCH_IDS),
        "supports_touch_reset": "resetButtonsToDefault" in setting_ids,
        "supports_touch_tone": "touchTone" in setting_ids,
        "has_left": "batteryLevelLeft" in setting_ids,
        "has_right": "batteryLevelRight" in setting_ids,
        "has_case": "caseBatteryLevel" in setting_ids,
        "has_tws": "twsStatus" in setting_ids,
    }


def mode_sets(caps):
    sets = {}
    if caps.get("supports_noise_off"):
        sets["off"] = ["ambientSoundMode=Normal"]
    if caps.get("supports_transparency"):
        sets["transparency"] = ["ambientSoundMode=Transparency"]
    if caps.get("supports_anc"):
        anc = ["ambientSoundMode=NoiseCanceling"]
        if caps.get("supports_adaptive"):
            sets["adaptive"] = anc + ["noiseCancelingMode=Adaptive"]
            sets["anc"] = anc + ["noiseCancelingMode=Manual"]
        else:
            sets["anc"] = anc
    return sets


def noise_from(ambient, cancel_mode):
    ambient = str(ambient or "")
    cancel_mode = str(cancel_mode or "")
    if ambient == "Normal":
        return NOISE_OFF
    if ambient == "Transparency":
        return NOISE_TRANSPARENCY
    if ambient == "NoiseCanceling" and cancel_mode == "Adaptive":
        return NOISE_ADAPTIVE
    if ambient == "NoiseCanceling":
        return NOISE_ANC
    return -1


def pod(level, charging, in_ear=False, in_case=False):
    available = level >= 0
    charging = bool(charging) if available else False
    in_case = bool(in_case) or charging
    return {
        "available": available,
        "level": level if available else 0,
        "charging": charging,
        "in_case": in_case if available else False,
        "in_ear": bool(in_ear) if available and not in_case else False,
    }


def update_in_case(prev, left_charging, right_charging, tws_connected, host):
    left = bool(prev.get("left"))
    right = bool(prev.get("right"))
    host = str(host or "").strip().lower()
    if left_charging:
        left = True
    if right_charging:
        right = True
    both_were_in = left and right
    if tws_connected:
        left = bool(left_charging)
        right = bool(right_charging)
    elif both_were_in and not left_charging and not right_charging:
        left = True
        right = True
    elif host == "left" and not left_charging and (right_charging or right):
        left = False
        right = True
    elif host == "right" and not right_charging and (left_charging or left):
        right = False
        left = True
    return {"left": left, "right": right}


def disconnected_status():
    return {
        "schema_version": 1,
        "connected": False,
        "device_name": "",
        "model_name": "",
        "model_id": "",
        "backend": "openscq30",
        "mac": "",
        "is_headset": False,
        "is_pro_series": False,
        "supports_noise_off": False,
        "supports_noise_control": False,
        "supports_adaptive": False,
        "supports_manual_anc": False,
        "manual_anc": -1,
        "manual_anc_min": 1,
        "manual_anc_max": 5,
        "adaptive_anc": -1,
        "adaptive_noise_level": 0,
        "noise_mode": -1,
        "left": pod(-1, False),
        "right": pod(-1, False),
        "case": pod(-1, False),
        "headset": pod(-1, False),
        "touch": {
            "available": False,
            "reset": False,
            "supports_tone": False,
            "tone": False,
            "controls": [],
        },
    }


def connected_status(chosen, settings, caps, in_case, setting_ids=None):
    left = fifths(settings.get("batteryLevelLeft"))
    right = fifths(settings.get("batteryLevelRight"))
    case = fifths(settings.get("caseBatteryLevel"))
    combined = bluez_battery(chosen["mac"])
    if left < 0 and right < 0 and combined >= 0:
        left = right = combined
    left_charging = yes(settings.get("isChargingLeft"))
    right_charging = yes(settings.get("isChargingRight"))
    tws = str(settings.get("twsStatus") or "").strip().lower() == "connected"
    is_headset = not caps.get("has_tws") and not (caps.get("has_left") and caps.get("has_right"))
    if caps.get("has_tws"):
        in_case = update_in_case(
            in_case, left_charging, right_charging, tws, settings.get("hostDevice")
        )
    else:
        in_case = {"left": False, "right": False}
    status = {
        "schema_version": 1,
        "connected": True,
        "device_name": chosen.get("bt_name") or chosen["name"],
        "model_name": chosen["name"],
        "model_id": chosen["id"],
        "backend": "openscq30",
        "mac": chosen["mac"],
        "is_headset": is_headset,
        "is_pro_series": False,
        "supports_noise_off": caps.get("supports_noise_off", False),
        "supports_noise_control": caps.get("supports_noise_control", False),
        "supports_adaptive": caps.get("supports_adaptive", False),
        "supports_manual_anc": caps.get("supports_manual_anc", False),
        "manual_anc": int_setting(settings.get("manualNoiseCanceling")),
        "manual_anc_min": caps.get("manual_anc_min", 1),
        "manual_anc_max": caps.get("manual_anc_max", 5),
        "adaptive_anc": int_setting(settings.get("adaptiveNoiseCanceling")),
        "adaptive_noise_level": 0,
        "noise_mode": noise_from(settings.get("ambientSoundMode"), settings.get("noiseCancelingMode")),
        "left": pod(left, left_charging, not in_case["left"], in_case["left"]),
        "right": pod(right, right_charging, not in_case["right"], in_case["right"]),
        "case": pod(case, left_charging or right_charging or (in_case["left"] and in_case["right"]))
        if caps.get("has_case")
        else pod(-1, False),
        "headset": pod(combined if combined >= 0 else max(left, right), False) if is_headset else pod(-1, False),
        "touch": touch_payload(setting_ids or {}, settings, caps),
    }
    return status, in_case


def write_status(payload):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, separators=(",", ":")) + "\n")
    tmp.replace(STATE_PATH)


def load_in_case():
    try:
        data = json.loads(STATE_PATH.read_text())
    except (OSError, json.JSONDecodeError):
        return {"left": False, "right": False}
    left = data.get("left") or {}
    right = data.get("right") or {}
    return {
        "left": bool(left.get("in_case") or left.get("charging")),
        "right": bool(right.get("in_case") or right.get("charging")),
    }


def ensure_paired(mac, model_id):
    listed = run([OPENSCQ30, "paired-devices", "list"], timeout=8)
    if mac.lower() in (listed.stdout or "").lower():
        return
    run(
        [OPENSCQ30, "paired-devices", "add", "--mac-address", mac, "--model", model_id],
        timeout=10,
    )


def apply_sets(mac, sets):
    args = ["setting"]
    for item in sets:
        args.extend(["--set", item])
    proc = openscq30_device(mac, args, timeout=20, retries=3)
    if proc.returncode == 0 or len(sets) <= 1:
        return proc
    first = openscq30_device(mac, ["setting", "--set", sets[0]], timeout=20, retries=2)
    if first.returncode != 0:
        return first
    time.sleep(0.4)
    rest = ["setting"]
    for item in sets[1:]:
        rest.extend(["--set", item])
    second = openscq30_device(mac, rest, timeout=20, retries=2)
    return second if second.returncode == 0 else first


def find_connected():
    models = load_models()
    if not models:
        return None
    return pick_device(models, bluetooth_devices())


def cmd_set_anc_level(raw):
    try:
        level = int(raw)
    except ValueError:
        print("ANC level must be an integer", file=sys.stderr)
        return 2
    chosen = find_connected()
    if not chosen:
        print("No supported Soundcore device is connected", file=sys.stderr)
        return 1
    with openscq30_lock():
        ensure_paired(chosen["mac"], chosen["id"])
        setting_ids = list_setting_ids(chosen["mac"])
        caps = capabilities(setting_ids)
        if not caps.get("supports_manual_anc"):
            print("this device has no adjustable ANC level", file=sys.stderr)
            return 2
        lo, hi = caps.get("manual_anc_min", 1), caps.get("manual_anc_max", 5)
        level = max(lo, min(hi, level))
        sets = ["ambientSoundMode=NoiseCanceling"]
        if caps.get("supports_adaptive"):
            sets.append("noiseCancelingMode=Manual")
        sets.append("manualNoiseCanceling=" + str(level))
        proc = apply_sets(chosen["mac"], sets)
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or "Could not change ANC level").strip()
            print(err, file=sys.stderr)
            return proc.returncode or 1
        settings = query_settings(chosen["mac"], setting_ids)
        if settings:
            payload, _ = connected_status(
                chosen, settings, caps, load_in_case(), setting_ids
            )
            write_status(payload)
        time.sleep(0.6)
    return 0


def cmd_set_touch(setting_id, value):
    if setting_id not in TOUCH_IDS:
        print("unknown touch control", file=sys.stderr)
        return 2
    chosen = find_connected()
    if not chosen:
        print("No supported Soundcore device is connected", file=sys.stderr)
        return 1
    with openscq30_lock():
        ensure_paired(chosen["mac"], chosen["id"])
        setting_ids = list_setting_ids(chosen["mac"])
        if setting_id not in setting_ids:
            print("this device has no " + setting_id, file=sys.stderr)
            return 2
        allowed = {row["id"] for row in touch_options(setting_ids, setting_id)}
        if value not in allowed:
            print("invalid touch action", file=sys.stderr)
            return 2
        proc = apply_sets(chosen["mac"], [setting_id + "=" + value])
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or "Could not change touch control").strip()
            print(err, file=sys.stderr)
            return proc.returncode or 1
        settings = query_settings(chosen["mac"], setting_ids)
        if settings:
            payload, _ = connected_status(
                chosen, settings, capabilities(setting_ids), load_in_case(), setting_ids
            )
            write_status(payload)
        time.sleep(0.6)
    return 0


def cmd_set_touch_reset():
    chosen = find_connected()
    if not chosen:
        print("No supported Soundcore device is connected", file=sys.stderr)
        return 1
    with openscq30_lock():
        ensure_paired(chosen["mac"], chosen["id"])
        setting_ids = list_setting_ids(chosen["mac"])
        if "resetButtonsToDefault" not in setting_ids:
            print("this device cannot reset touch controls", file=sys.stderr)
            return 2
        proc = apply_sets(chosen["mac"], ["resetButtonsToDefault="])
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or "Could not reset touch controls").strip()
            print(err, file=sys.stderr)
            return proc.returncode or 1
        settings = query_settings(chosen["mac"], setting_ids)
        if settings:
            payload, _ = connected_status(
                chosen, settings, capabilities(setting_ids), load_in_case(), setting_ids
            )
            write_status(payload)
        time.sleep(0.6)
    return 0


def cmd_set_touch_tone(raw):
    on = str(raw or "").strip().lower() in ("1", "true", "yes", "on")
    chosen = find_connected()
    if not chosen:
        print("No supported Soundcore device is connected", file=sys.stderr)
        return 1
    with openscq30_lock():
        ensure_paired(chosen["mac"], chosen["id"])
        setting_ids = list_setting_ids(chosen["mac"])
        if "touchTone" not in setting_ids:
            print("this device has no touch tone setting", file=sys.stderr)
            return 2
        proc = apply_sets(chosen["mac"], ["touchTone=" + ("true" if on else "false")])
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or "Could not change touch tone").strip()
            print(err, file=sys.stderr)
            return proc.returncode or 1
        settings = query_settings(chosen["mac"], setting_ids)
        if settings:
            payload, _ = connected_status(
                chosen, settings, capabilities(setting_ids), load_in_case(), setting_ids
            )
            write_status(payload)
        time.sleep(0.6)
    return 0


LIBREPODS_NOISE = {
    "off": "noise:off",
    "anc": "noise:anc",
    "transparency": "noise:transparency",
    "adaptive": "noise:adaptive",
}


def cmd_set_librepods(mode):
    verb = LIBREPODS_NOISE.get(mode)
    if not verb:
        print(f"this device has no {mode} mode", file=sys.stderr)
        return 2
    proc = run([LIBREPODS_CTL, verb], timeout=12)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "librepods-ctl rejected the command").strip()
        print(err, file=sys.stderr)
        return proc.returncode or 1
    return 0


def cmd_set_adaptive_level(raw):
    try:
        level = max(0, min(100, int(raw)))
    except ValueError:
        print("adaptive level must be an integer", file=sys.stderr)
        return 2
    proc = run([LIBREPODS_CTL, "adaptive:" + str(level)], timeout=12)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "Could not change adaptive level").strip()
        print(err, file=sys.stderr)
        return proc.returncode or 1
    return 0


def cmd_set(mode):
    target = pick_target(load_models(), bluetooth_devices())
    if not target:
        print("No supported headphones are connected", file=sys.stderr)
        return 1
    if target.get("backend") == "librepods":
        return cmd_set_librepods(mode)
    if target.get("backend") != "openscq30":
        print("this device has no listening-mode controls on Linux", file=sys.stderr)
        return 2
    chosen = {
        "mac": target["mac"],
        "bt_name": target.get("bt_name"),
        "id": target["id"],
        "name": target["name"],
    }
    with openscq30_lock():
        ensure_paired(chosen["mac"], chosen["id"])
        setting_ids = list_setting_ids(chosen["mac"])
        sets = mode_sets(capabilities(setting_ids)).get(mode)
        if not sets:
            print(f"this device has no {mode} mode", file=sys.stderr)
            return 2
        proc = apply_sets(chosen["mac"], sets)
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or "Could not change listening mode").strip()
            print(err, file=sys.stderr)
            return proc.returncode or 1
        settings = query_settings(chosen["mac"], setting_ids)
        if settings:
            payload, _ = connected_status(
                chosen, settings, capabilities(setting_ids), load_in_case(), setting_ids
            )
            write_status(payload)
        time.sleep(0.6)
    return 0


def main():
    last = None
    in_case = {"left": False, "right": False}
    models = []
    models_at = 0
    while True:
        now = time.time()
        if now - models_at > 60:
            models = load_models()
            models_at = now
        target = pick_target(models, bluetooth_devices()) if models else None
        if not target:
            payload = disconnected_status()
            in_case = {"left": False, "right": False}
            interval = POLL_IDLE
        elif target.get("backend") == "librepods":
            payload = status_from_librepods(target)
            in_case = {"left": False, "right": False}
            interval = POLL_CONNECTED
        elif target.get("backend") == "bluez":
            payload = status_from_bluez(target)
            in_case = {"left": False, "right": False}
            interval = POLL_IDLE
        else:
            chosen = {
                "mac": target["mac"],
                "bt_name": target.get("bt_name"),
                "id": target["id"],
                "name": target["name"],
            }
            ensure_paired(chosen["mac"], chosen["id"])
            with openscq30_lock():
                setting_ids = list_setting_ids(chosen["mac"])
                settings = query_settings(chosen["mac"], setting_ids) if setting_ids else None
            if not settings:
                time.sleep(POLL_CONNECTED)
                continue
            payload, in_case = connected_status(
                chosen, settings, capabilities(setting_ids), in_case, setting_ids
            )
            interval = POLL_CONNECTED
        encoded = json.dumps(payload, separators=(",", ":"))
        if encoded != last:
            write_status(payload)
            last = encoded
        time.sleep(interval)


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "set":
        which = sys.argv[2].strip().lower()
        if which in ("anc-level", "anc_level") and len(sys.argv) >= 4:
            sys.exit(cmd_set_anc_level(sys.argv[3]))
        if which in ("adaptive-level", "adaptive_level") and len(sys.argv) >= 4:
            sys.exit(cmd_set_adaptive_level(sys.argv[3]))
        if which == "touch":
            sys.exit(cmd_set_touch(sys.argv[3] if len(sys.argv) >= 4 else "", sys.argv[4] if len(sys.argv) >= 5 else ""))
        if which in ("touch-reset", "touch_reset"):
            sys.exit(cmd_set_touch_reset())
        if which in ("touch-tone", "touch_tone"):
            sys.exit(cmd_set_touch_tone(sys.argv[3] if len(sys.argv) >= 4 else "false"))
        sys.exit(cmd_set(which))
    main()
