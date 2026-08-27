#!/usr/bin/env bash
# Blast a locator tone on the left, right, or both channels of the connected
# Soundcore sink. The panel warns before it runs this; CLI callers do not.
set -euo pipefail

SIDE="${1:-}"
RUNTIME="${XDG_RUNTIME_DIR:-/tmp}"
PIDFILE="$RUNTIME/better-omapods-find.pid"
VOLFILE="$RUNTIME/better-omapods-find.vol"
MUTEFILE="$RUNTIME/better-omapods-find.mute"
SINKFILE="$RUNTIME/better-omapods-find.sink"
WAVFILE="$RUNTIME/better-omapods-find.wav"
LIMITFILE="$RUNTIME/better-omapods-find.limit"
PLAYERSFILE="$RUNTIME/better-omapods-find.players"
HOLDFILE="$RUNTIME/better-omapods-find.hold"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/better-omapods"
STATE_JSON="$STATE_DIR/status.json"
LOCK_PATH="$STATE_DIR/openscq30.lock"
OPENSCQ30="${OPENSCQ30:-$HOME/.local/bin/openscq30}"
if [[ ! -x $OPENSCQ30 ]]; then
  OPENSCQ30="$(command -v openscq30 || true)"
fi

soundcore_mac() {
  python3 -c 'import json,sys
try:
  print(json.load(open(sys.argv[1])).get("mac") or "")
except Exception:
  print("")' "$STATE_JSON" 2>/dev/null || true
}

openscq30_locked() {
  [[ -n ${OPENSCQ30:-} && -x $OPENSCQ30 ]] || return 0
  mkdir -p "$STATE_DIR"
  : >>"$LOCK_PATH"
  flock "$LOCK_PATH" "$OPENSCQ30" "$@"
}

stop_tone() {
  if [[ -f $PIDFILE ]]; then
    local pid
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [[ -n ${pid:-} ]]; then
      kill "$pid" 2>/dev/null || true
      pkill -P "$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
  fi
  pkill -f "better-omapods-find-tone" 2>/dev/null || true
  if [[ -f $SINKFILE && -f $VOLFILE ]]; then
    local sink vol
    sink=$(cat "$SINKFILE" 2>/dev/null || true)
    vol=$(cat "$VOLFILE" 2>/dev/null || true)
    if [[ -n ${sink:-} && -n ${vol:-} ]]; then
      pactl set-sink-volume "$sink" "$vol" 2>/dev/null || true
    fi
  fi
  if [[ -f $SINKFILE && -f $MUTEFILE ]]; then
    local sink mute
    sink=$(cat "$SINKFILE" 2>/dev/null || true)
    mute=$(cat "$MUTEFILE" 2>/dev/null || true)
    if [[ -n ${sink:-} && -n ${mute:-} ]]; then
      pactl set-sink-mute "$sink" "$mute" 2>/dev/null || true
    fi
  fi
  if [[ -f $LIMITFILE ]]; then
    local mac limit
    mac=$(soundcore_mac)
    limit=$(cat "$LIMITFILE" 2>/dev/null || true)
    if [[ -n ${mac:-} && -n ${limit:-} ]]; then
      openscq30_locked device --mac-address "$mac" setting \
        --set "limitHighVolumeDbLimit=${limit}" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$VOLFILE" "$MUTEFILE" "$SINKFILE" "$WAVFILE" "$LIMITFILE"
}

pause_playback() {
  : >>"$PLAYERSFILE"
  local dest status
  while read -r dest _; do
    [[ $dest == org.mpris.MediaPlayer2.* ]] || continue
    status=$(busctl --user get-property "$dest" /org/mpris/MediaPlayer2 \
      org.mpris.MediaPlayer2.Player PlaybackStatus 2>/dev/null || true)
    if [[ $status == *Playing* ]]; then
      grep -qxF "$dest" "$PLAYERSFILE" 2>/dev/null || echo "$dest" >>"$PLAYERSFILE"
      busctl --user call "$dest" /org/mpris/MediaPlayer2 \
        org.mpris.MediaPlayer2.Player Pause >/dev/null 2>&1 || true
    fi
  done < <(busctl --user list --no-legend 2>/dev/null || true)
}

resume_playback() {
  [[ -f $PLAYERSFILE ]] || return 0
  local dest
  while IFS= read -r dest; do
    [[ -n $dest ]] || continue
    busctl --user call "$dest" /org/mpris/MediaPlayer2 \
      org.mpris.MediaPlayer2.Player Play >/dev/null 2>&1 || true
  done <"$PLAYERSFILE"
  rm -f "$PLAYERSFILE"
}

finish_find() {
  stop_tone
  if [[ -f $HOLDFILE ]]; then
    return 0
  fi
  resume_playback
}

trap 'finish_find' EXIT TERM INT

sink_for_device() {
  local mac=""
  if [[ -f $STATE_JSON ]]; then
    mac=$(soundcore_mac)
  fi
  mac=${mac//:/_}

  while IFS=$'\t' read -r _ name _ _ _; do
    [[ $name == bluez_output.* ]] || continue
    if [[ -n $mac && $name == *"$mac"* ]]; then
      echo "$name"
      return 0
    fi
  done < <(pactl list short sinks)

  pactl list sinks | awk '
    $1=="Name:" {name=$2}
    $1=="Description:" {
      desc=tolower($0)
      if (name ~ /^bluez_output\./ && (desc ~ /soundcore/ || desc ~ /p40i/ || desc ~ /liberty/ || desc ~ /space q/ || desc ~ /q30/ || desc ~ /airpods/ || desc ~ /beats/ || desc ~ /sony/ || desc ~ /bose/ || desc ~ /galaxy/ || desc ~ /buds/)) {
        print name
        found=1
        exit
      }
    }
    END { if (!found) exit 1 }
  '
}

boost_stream() {
  local n=0 idx
  while (( n < 30 )); do
    idx=$(pactl list sink-inputs 2>/dev/null | awk '
      /^Sink Input #/ { id=$3; gsub(/#/,"",id) }
      /better-omapods-find-tone/ { print id; exit }
    ')
    if [[ -n ${idx:-} ]]; then
      pactl set-sink-input-mute "$idx" 0 2>/dev/null || true
      pactl set-sink-input-volume "$idx" 180% 2>/dev/null || true
      return 0
    fi
    sleep 0.1
    n=$((n + 1))
  done
}

if [[ $SIDE == stop ]]; then
  if [[ ${2:-} == --hold ]]; then
    : >"$HOLDFILE"
  else
    rm -f "$HOLDFILE"
  fi
  had_pid=0
  if [[ -f $PIDFILE ]]; then
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [[ -n ${pid:-} ]] && kill -0 "$pid" 2>/dev/null; then
      had_pid=1
    fi
  fi
  stop_tone
  if [[ $had_pid -eq 0 && ${2:-} != --hold ]]; then
    resume_playback
  fi
  exit 0
fi

if [[ $SIDE != left && $SIDE != right && $SIDE != both ]]; then
  echo "usage: find.sh left|right|both|stop" >&2
  exit 2
fi

SINK=$(sink_for_device) || {
  echo "No Bluetooth headphones sink. Connect the Soundcore device first." >&2
  exit 1
}

stop_tone
pause_playback
rm -f "$HOLDFILE"
trap 'finish_find' EXIT TERM INT

echo "$SINK" > "$SINKFILE"
pactl get-sink-volume "$SINK" | awk '{print $5; exit}' > "$VOLFILE"
pactl get-sink-mute "$SINK" | awk '{print ($2=="yes")?"1":"0"}' > "$MUTEFILE"
pactl set-sink-mute "$SINK" 0
# Hardware volume is already 100%; this extra 200% is PipeWire software gain (+18 dB).
pactl set-sink-volume "$SINK" 200%

MAC=$(soundcore_mac)
if [[ -n $MAC ]]; then
  openscq30_locked device --mac-address "$MAC" setting -g limitHighVolumeDbLimit 2>/dev/null \
    | awk 'NR>1 && $1=="limitHighVolumeDbLimit" {print $2; exit}' > "$LIMITFILE" || true
  openscq30_locked device --mac-address "$MAC" setting \
    --set "limitHighVolume=false" --set "limitHighVolumeDbLimit=100" >/dev/null 2>&1 || true
fi

# Dual-tone ~3 kHz alarm at 0 dBFS, 8 beeps/sec, hard-panned unless both.
python3 - "$WAVFILE" "$SIDE" <<'PY'
import math, sys, wave
from array import array

path, side = sys.argv[1], sys.argv[2]
sr, dur = 48000, 20
n = sr * dur
buf = array("h")
period = sr // 8
on = int(sr * 0.08)
for i in range(n):
    if (i % period) >= on:
        s = 0
    else:
        t = i / sr
        freq = 3000 + 450 * math.sin(2 * math.pi * 16 * t)
        s = int(0.99 * math.sin(2 * math.pi * freq * t) * 32767)
    if side == "left":
        buf.append(s)
        buf.append(0)
    elif side == "right":
        buf.append(0)
        buf.append(s)
    else:
        buf.append(s)
        buf.append(s)
with wave.open(path, "w") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes(buf.tobytes())
PY

paplay --device="$SINK" --volume=65536 --stream-name=better-omapods-find-tone "$WAVFILE" &
echo $! > "$PIDFILE"
boost_stream &
wait || true
