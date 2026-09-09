#!/usr/bin/env bash
# Blast a locator tone on the left, right, or both channels of the connected
# Soundcore sink. The panel warns before it runs this; CLI callers do not.
#
# Runtime files live in an owner-only directory under XDG_RUNTIME_DIR. There
# is no /tmp fallback: a shared temp dir is how a same-UID attacker redirects
# PID/volume restoration. Volume is captured into this process before it is
# raised, and restoration prefers that held state.
set -euo pipefail

SIDE="${1:-}"
UID_NUM="$(id -u)"
RUNTIME_BASE="${XDG_RUNTIME_DIR:-/run/user/$UID_NUM}"

owned_dir() {
  local path=$1
  [[ -n $path && -d $path && ! -L $path ]] || return 1
  [[ $(stat -c '%u %F' "$path" 2>/dev/null) == "$UID_NUM directory" ]]
}

if ! owned_dir "$RUNTIME_BASE"; then
  echo "No private XDG_RUNTIME_DIR; refusing to use shared /tmp." >&2
  exit 1
fi

WORKDIR="$RUNTIME_BASE/better-omapods"
if [[ -L $WORKDIR ]]; then
  echo "better-omapods runtime path is a symlink" >&2
  exit 1
fi
mkdir -m 700 -p "$WORKDIR"
chmod 700 "$WORKDIR" 2>/dev/null || true
if ! owned_dir "$WORKDIR"; then
  echo "better-omapods runtime directory is not owner-only" >&2
  exit 1
fi

# Exclusive no-follow regular files inside WORKDIR.
create_file() {
  python3 - "$1" <<'PY'
import os, sys
path = sys.argv[1]
flags = os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
try:
    fd = os.open(path, flags, 0o600)
except FileExistsError:
    os.remove(path)
    fd = os.open(path, flags, 0o600)
try:
    st = os.fstat(fd)
    if not (st.st_mode & 0o170000) == 0o100000:
        raise SystemExit("not a regular file")
    if st.st_uid != os.getuid():
        raise SystemExit("unexpected owner")
finally:
    os.close(fd)
PY
}

write_file() {
  python3 - "$1" "$2" <<'PY'
import os, sys
path, data = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_TRUNC)
try:
    st = os.fstat(fd)
    if not (st.st_mode & 0o170000) == 0o100000 or st.st_uid != os.getuid():
        raise SystemExit("refusing to write")
    os.write(fd, data.encode())
finally:
    os.close(fd)
PY
}

read_file() {
  python3 - "$1" <<'PY'
import os, sys
path = sys.argv[1]
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
except OSError:
    sys.exit(0)
try:
    st = os.fstat(fd)
    if not (st.st_mode & 0o170000) == 0o100000 or st.st_uid != os.getuid():
        sys.exit(0)
    data = os.read(fd, 4096)
finally:
    os.close(fd)
sys.stdout.buffer.write(data)
PY
}

remove_file() {
  local path=$1
  [[ -e $path || -L $path ]] || return 0
  [[ -L $path ]] && { rm -f -- "$path"; return 0; }
  [[ -f $path ]] || return 0
  [[ $(stat -c '%u' "$path" 2>/dev/null) == "$UID_NUM" ]] || return 0
  rm -f -- "$path"
}

PIDFILE="$WORKDIR/find.pid"
VOLFILE="$WORKDIR/find.vol"
MUTEFILE="$WORKDIR/find.mute"
SINKFILE="$WORKDIR/find.sink"
WAVFILE="$WORKDIR/find.wav"
LIMITFILE="$WORKDIR/find.limit"
PLAYERSFILE="$WORKDIR/find.players"
HOLDFILE="$WORKDIR/find.hold"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/better-omapods"
STATE_JSON="$STATE_DIR/status.json"
LOCK_PATH="$STATE_DIR/openscq30.lock"
OPENSCQ30="${OPENSCQ30:-$HOME/.local/bin/openscq30}"
if [[ ! -x $OPENSCQ30 ]]; then
  OPENSCQ30="$(command -v openscq30 || true)"
fi

# Held in this process so a crash of the file store cannot invent a restore.
ORIG_SINK=""
ORIG_VOL=""
ORIG_MUTE=""
ORIG_LIMIT=""
ORIG_MAC=""
HELD=0

soundcore_mac() {
  python3 -c 'import json,os,stat,sys
path=sys.argv[1]
try:
  fd=os.open(path, os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
except OSError:
  print(""); raise SystemExit
try:
  st=os.fstat(fd)
  if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.getuid() or st.st_size>65536:
    print("")
  else:
    data=os.read(fd, 65536)
finally:
  os.close(fd)
try:
  print(json.loads(data.decode()).get("mac") or "")
except Exception:
  print("")' "$STATE_JSON" 2>/dev/null || true
}

openscq30_locked() {
  [[ -n ${OPENSCQ30:-} && -x $OPENSCQ30 ]] || return 0
  mkdir -p "$STATE_DIR"
  : >>"$LOCK_PATH"
  flock "$LOCK_PATH" "$OPENSCQ30" "$@"
}

valid_sink() {
  [[ $1 =~ ^bluez_output\.[A-Za-z0-9_.-]+$ ]]
}

valid_volume() {
  [[ $1 =~ ^[0-9]{1,3}%$ ]] || return 1
  local n=${1%\%}
  (( n >= 0 && n <= 150 ))
}

valid_mute() {
  [[ $1 == 0 || $1 == 1 ]]
}

valid_limit() {
  [[ $1 =~ ^[0-9]{1,3}$ ]] || return 1
  (( $1 >= 0 && $1 <= 100 ))
}

valid_mac() {
  [[ $1 =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

is_our_tone_pid() {
  local pid=$1
  [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
  [[ -d /proc/$pid && ! -L /proc/$pid ]] || return 1
  [[ $(stat -c '%u' "/proc/$pid" 2>/dev/null) == "$UID_NUM" ]] || return 1
  local cmd
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
  [[ $cmd == *paplay* && $cmd == *better-omapods-find-tone* ]]
}

kill_our_tone() {
  local pid
  pid=$(read_file "$PIDFILE" 2>/dev/null || true)
  pid=${pid//$'\n'/}
  if is_our_tone_pid "$pid"; then
    local child
    while read -r child; do
      [[ $child =~ ^[1-9][0-9]*$ ]] || continue
      [[ $(stat -c '%u' "/proc/$child" 2>/dev/null) == "$UID_NUM" ]] || continue
      kill "$child" 2>/dev/null || true
    done < <(ps -o pid= --ppid "$pid" 2>/dev/null || true)
    kill "$pid" 2>/dev/null || true
  fi
  remove_file "$PIDFILE"
}

restore_audio() {
  local sink vol mute mac limit
  if [[ $HELD -eq 1 ]]; then
    sink=$ORIG_SINK
    vol=$ORIG_VOL
    mute=$ORIG_MUTE
    mac=$ORIG_MAC
    limit=$ORIG_LIMIT
  else
    sink=$(read_file "$SINKFILE" 2>/dev/null || true)
    vol=$(read_file "$VOLFILE" 2>/dev/null || true)
    mute=$(read_file "$MUTEFILE" 2>/dev/null || true)
    mac=$(soundcore_mac)
    limit=$(read_file "$LIMITFILE" 2>/dev/null || true)
    sink=${sink//$'\n'/}
    vol=${vol//$'\n'/}
    mute=${mute//$'\n'/}
    limit=${limit//$'\n'/}
  fi
  if valid_sink "$sink" && valid_volume "$vol"; then
    pactl set-sink-volume "$sink" "$vol" 2>/dev/null || true
  fi
  if valid_sink "$sink" && valid_mute "$mute"; then
    pactl set-sink-mute "$sink" "$mute" 2>/dev/null || true
  fi
  if valid_mac "$mac" && valid_limit "$limit"; then
    openscq30_locked device --mac-address "$mac" setting \
      --set "limitHighVolumeDbLimit=${limit}" >/dev/null 2>&1 || true
  fi
}

stop_tone() {
  kill_our_tone
  restore_audio
  remove_file "$VOLFILE"
  remove_file "$MUTEFILE"
  remove_file "$SINKFILE"
  remove_file "$WAVFILE"
  remove_file "$LIMITFILE"
}

pause_playback() {
  local dest status players=""
  while read -r dest _; do
    [[ $dest == org.mpris.MediaPlayer2.* ]] || continue
    status=$(busctl --user get-property "$dest" /org/mpris/MediaPlayer2 \
      org.mpris.MediaPlayer2.Player PlaybackStatus 2>/dev/null || true)
    if [[ $status == *Playing* ]]; then
      players+="$dest"$'\n'
      busctl --user call "$dest" /org/mpris/MediaPlayer2 \
        org.mpris.MediaPlayer2.Player Pause >/dev/null 2>&1 || true
    fi
  done < <(busctl --user list --no-legend 2>/dev/null || true)
  create_file "$PLAYERSFILE"
  write_file "$PLAYERSFILE" "$players"
}

resume_playback() {
  [[ -f $PLAYERSFILE && ! -L $PLAYERSFILE ]] || return 0
  local dest
  while IFS= read -r dest; do
    [[ $dest == org.mpris.MediaPlayer2.* ]] || continue
    busctl --user call "$dest" /org/mpris/MediaPlayer2 \
      org.mpris.MediaPlayer2.Player Play >/dev/null 2>&1 || true
  done < <(read_file "$PLAYERSFILE")
  remove_file "$PLAYERSFILE"
}

finish_find() {
  stop_tone
  if [[ -f $HOLDFILE && ! -L $HOLDFILE ]]; then
    return 0
  fi
  resume_playback
}

trap 'finish_find' EXIT TERM INT

sink_for_device() {
  local mac=""
  if [[ -f $STATE_JSON && ! -L $STATE_JSON ]]; then
    mac=$(soundcore_mac)
  fi
  mac=${mac//:/_}

  while IFS=$'\t' read -r _ name _ _ _; do
    valid_sink "$name" || continue
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
    if [[ ${idx:-} =~ ^[0-9]+$ ]]; then
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
    create_file "$HOLDFILE"
    write_file "$HOLDFILE" "1"
  else
    remove_file "$HOLDFILE"
  fi
  had_pid=0
  pid=$(read_file "$PIDFILE" 2>/dev/null || true)
  pid=${pid//$'\n'/}
  if is_our_tone_pid "$pid"; then
    had_pid=1
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
valid_sink "$SINK" || {
  echo "Refusing unexpected sink name." >&2
  exit 1
}

stop_tone
pause_playback
remove_file "$HOLDFILE"
trap 'finish_find' EXIT TERM INT

VOL=$(pactl get-sink-volume "$SINK" | awk '{print $5; exit}')
MUTE=$(pactl get-sink-mute "$SINK" | awk '{print ($2=="yes")?"1":"0"}')
if ! valid_volume "$VOL" || ! valid_mute "$MUTE"; then
  echo "Could not capture a restorable volume; refusing to raise it." >&2
  exit 1
fi

ORIG_SINK=$SINK
ORIG_VOL=$VOL
ORIG_MUTE=$MUTE
HELD=1

create_file "$SINKFILE"; write_file "$SINKFILE" "$SINK"
create_file "$VOLFILE"; write_file "$VOLFILE" "$VOL"
create_file "$MUTEFILE"; write_file "$MUTEFILE" "$MUTE"

pactl set-sink-mute "$SINK" 0
# Hardware volume is already 100%; this extra 200% is PipeWire software gain (+18 dB).
pactl set-sink-volume "$SINK" 200%

MAC=$(soundcore_mac)
if valid_mac "$MAC"; then
  ORIG_MAC=$MAC
  LIMIT=$(openscq30_locked device --mac-address "$MAC" setting -g limitHighVolumeDbLimit 2>/dev/null \
    | awk 'NR>1 && $1=="limitHighVolumeDbLimit" {print $2; exit}' || true)
  if valid_limit "$LIMIT"; then
    ORIG_LIMIT=$LIMIT
    create_file "$LIMITFILE"; write_file "$LIMITFILE" "$LIMIT"
  fi
  openscq30_locked device --mac-address "$MAC" setting \
    --set "limitHighVolume=false" --set "limitHighVolumeDbLimit=100" >/dev/null 2>&1 || true
fi

create_file "$WAVFILE"
# Dual-tone ~3 kHz alarm at 0 dBFS, 8 beeps/sec, hard-panned unless both.
python3 - "$WAVFILE" "$SIDE" <<'PY'
import math, os, sys, wave
from array import array

path, side = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_TRUNC)
try:
    st = os.fstat(fd)
    if not (st.st_mode & 0o170000) == 0o100000 or st.st_uid != os.getuid():
        raise SystemExit("refusing wav path")
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
            buf.extend((s, 0))
        elif side == "right":
            buf.extend((0, s))
        else:
            buf.extend((s, s))
    with os.fdopen(fd, "wb") as raw:
        fd = None
        with wave.open(raw, "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(sr)
            w.writeframes(buf.tobytes())
finally:
    if fd is not None:
        os.close(fd)
PY

paplay --device="$SINK" --volume=65536 --stream-name=better-omapods-find-tone "$WAVFILE" &
TONE_PID=$!
create_file "$PIDFILE"
write_file "$PIDFILE" "$TONE_PID"
boost_stream &
wait "$TONE_PID" || true
