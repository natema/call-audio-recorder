#!/usr/bin/env bash
# Record videocall audio: microphone + what the speakers/headphones play.
#
# Captures the PulseAudio/PipeWire default source and the monitor of the default
# sink with a single ffmpeg process (48 kHz), then builds an echo-cancelled mix
# after the recording stops. Does not change system volume or routing.
#
# Usage:
#   record-call.sh              # record in this terminal (Ctrl+C to stop)
#   record-call.sh --launch     # tray icon (keyboard shortcut; press again to stop)
#   record-call.sh --terminal   # terminal window instead of the tray icon
#   record-call.sh --duration N # record N seconds then stop (for tests)
#   record-call.sh --help
#
# Environment:
#   CALL_REC_LOCAL_DIR  where the FLAC tracks go (default ~/Recordings/call-recorder)
#   CALL_REC_SHARE_DIR  optional folder that receives only the mixed Opus file
#                       (CALL_REC_DIR is accepted as an alias)

set -euo pipefail

SELF="$(readlink -f "$0")"
HERE="$(dirname "$SELF")"
LOCK_DIR="${XDG_RUNTIME_DIR:-/tmp}/call-recorder"
LOCK_FILE="${LOCK_DIR}/recording.lock"
TRAY_LOCK="${LOCK_DIR}/tray.lock"
STATUS_FILE="${LOCK_DIR}/status"
STAGING_ROOT="${HOME}/.local/share/call-recorder/in-progress"
LOCAL_ROOT="${CALL_REC_LOCAL_DIR:-${HOME}/Recordings/call-recorder}"
# Optional. Empty means: keep the mixed Opus next to the FLAC files.
SHARE_ROOT="${CALL_REC_SHARE_DIR:-${CALL_REC_DIR:-}}"

DURATION=""
MODE="record"
HEADLESS=0

usage() {
  cat <<EOF
Record microphone + speaker audio for later transcription.

  $SELF
      Start recording in the current terminal. Stop with Ctrl+C.

  $SELF --launch
      Show a top-bar tray icon and start recording (keyboard shortcut).
      Press the shortcut again, or use the icon menu, to stop.

  $SELF --terminal
      Open a terminal window instead of the tray icon.

Options:
  --local-dir DIR   Where the recordings go
                    (default: \$CALL_REC_LOCAL_DIR or ~/Recordings/call-recorder).
  --share-dir DIR   Optional second folder that receives only the mixed Opus
                    file, e.g. a synced folder such as Dropbox/Nextcloud
                    (default: \$CALL_REC_SHARE_DIR, unset = no share folder).
                    --output-dir is an alias.
  --duration N      Stop automatically after N seconds.
  --headless        No terminal UI (used by the tray icon).
  -h, --help        Show this help.

Files (written after you stop), <stamp> = YYYY-MM-DD_HH-MM-SS:
  <local-dir>/<stamp>/
      mixed.flac     echo-cancelled mix of microphone + speakers
      mic.flac       microphone only
      speakers.flac  speaker/headphone playback only
      mixed.opus     compact copy of the mix, for transcription
      info.txt, ffmpeg.log
  <share-dir>/<stamp>.opus
      With a share folder, the Opus file goes there instead of <local-dir>.

Does not change volume, default devices, or Pulse/PipeWire routing.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --launch) MODE="launch"; shift ;;
    --terminal) MODE="terminal"; shift ;;
    --headless) HEADLESS=1; shift ;;
    --duration)
      DURATION="${2:-}"
      [[ "$DURATION" =~ ^[0-9]+$ ]] || { echo "Invalid --duration" >&2; exit 2; }
      shift 2
      ;;
    --output-dir|--share-dir)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      SHARE_ROOT="$2"
      shift 2
      ;;
    --local-dir)
      [[ -n "${2:-}" ]] || { echo "Missing value for $1" >&2; exit 2; }
      LOCAL_ROOT="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

alive_pid_from() {
  local file="$1" pid=""
  [[ -f "$file" ]] || return 1
  pid="$(cat "$file" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

is_recording() {
  alive_pid_from "$LOCK_FILE"
}

notify() {
  if command -v notify-send >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    notify-send --app-name="Call recorder" --icon=media-record "$1" "${2:-}" || true
  fi
}

stop_if_running() {
  local pid=""
  if alive_pid_from "$TRAY_LOCK"; then
    pid="$(cat "$TRAY_LOCK")"
  elif is_recording; then
    pid="$(cat "$LOCK_FILE")"
  else
    return 1
  fi
  kill -INT "$pid" 2>/dev/null || true
  return 0
}

tray_available() {
  python3 -c 'import gi; gi.require_version("Gtk","3.0"); gi.require_version("AyatanaAppIndicator3","0.1")' 2>/dev/null
}

launch_terminal() {
  need_cmd gnome-terminal
  local launch_args=("$SELF" --share-dir "$SHARE_ROOT" --local-dir "$LOCAL_ROOT")
  [[ -n "$DURATION" ]] && launch_args+=(--duration "$DURATION")
  exec gnome-terminal \
    --title="Call recorder" \
    --geometry=92x24 \
    -- bash -- "${launch_args[@]}"
}

launch_tray() {
  local launch_args=("${HERE}/record-call-tray.py" --share-dir "$SHARE_ROOT" --local-dir "$LOCAL_ROOT")
  [[ -n "$DURATION" ]] && launch_args+=(--duration "$DURATION")
  exec python3 "${launch_args[@]}"
}

if [[ "$MODE" == "launch" || "$MODE" == "terminal" ]]; then
  mkdir -p "$LOCK_DIR"
  if stop_if_running; then
    exit 0
  fi
  if [[ "$MODE" == "terminal" ]] || ! tray_available; then
    launch_terminal
  fi
  launch_tray
fi

need_cmd pactl
need_cmd ffmpeg

device_description() {
  local kind="$1" name="$2"
  pactl list "$kind" | awk -v n="$name" '
    $1=="Name:" && $2==n { hit=1 }
    hit && $1=="Description:" {
      sub(/^[[:space:]]*Description:[[:space:]]*/, "")
      print
      exit
    }
  '
}

MIC="$(pactl get-default-source)"
SINK="$(pactl get-default-sink)"
MONITOR="${SINK}.monitor"

if [[ -z "$MIC" || -z "$SINK" ]]; then
  echo "Could not read Pulse/PipeWire default source/sink." >&2
  exit 1
fi

if ! pactl list short sources | awk '{print $2}' | grep -Fxq "$MONITOR"; then
  echo "No monitor source for default sink:" >&2
  echo "  $SINK" >&2
  echo "Speaker audio cannot be recorded." >&2
  exit 1
fi

MIC_DESC="$(device_description sources "$MIC")"
SINK_DESC="$(device_description sinks "$SINK")"
MONITOR_DESC="$(device_description sources "$MONITOR")"
MIC_DESC="${MIC_DESC:-$MIC}"
SINK_DESC="${SINK_DESC:-$SINK}"
MONITOR_DESC="${MONITOR_DESC:-$MONITOR}"

STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
SESSION="${STAMP}"
STAGING="${STAGING_ROOT}/${SESSION}"
LOCAL_DEST="${LOCAL_ROOT}/${SESSION}"
# Where the mixed Opus ends up: inside the session folder, or (when a share
# folder is configured) as a single <stamp>.opus file in that folder.
opus_target() {
  if [[ -n "$SHARE_ROOT" ]]; then
    echo "${SHARE_ROOT}/${SESSION}.opus"
  else
    echo "${LOCAL_DEST}/mixed.opus"
  fi
}
SHARE_FILE="$(opus_target)"
i=1
while [[ -e "$STAGING" || -e "$LOCAL_DEST" || -e "$SHARE_FILE" ]]; do
  SESSION="${STAMP}-${i}"
  STAGING="${STAGING_ROOT}/${SESSION}"
  LOCAL_DEST="${LOCAL_ROOT}/${SESSION}"
  SHARE_FILE="$(opus_target)"
  i=$((i + 1))
done

mkdir -p "$STAGING" "$LOCK_DIR"

if is_recording; then
  echo "Already recording (pid $(cat "$LOCK_FILE"))." >&2
  exit 1
fi
echo $$ >"$LOCK_FILE"

FFMPEG_PID=""
FFMPEG_LOG="${STAGING}/ffmpeg.log"
MIXED="${STAGING}/mixed.flac"
MIC_FILE="${STAGING}/mic.flac"
SPK_FILE="${STAGING}/speakers.flac"
STARTED_EPOCH="$(date +%s)"
USE_COLOR=0
if [[ "$HEADLESS" -eq 0 && -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
  USE_COLOR=1
fi

write_status() {
  cat >"$STATUS_FILE" <<EOF
pid=$$
started=${STARTED_EPOCH}
staging=${STAGING}
dest=${SHARE_FILE}
local_dest=${LOCAL_DEST}
mic_description=${MIC_DESC}
sink_description=${SINK_DESC}
state=${1}
EOF
}

restore_cursor() {
  if [[ "$USE_COLOR" -eq 1 ]]; then
    tput cnorm 2>/dev/null || true
  fi
}

cleanup() {
  if [[ -n "${FFMPEG_PID}" ]] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
    kill -INT "$FFMPEG_PID" 2>/dev/null || true
  fi
  restore_cursor
  if [[ -f "$LOCK_FILE" ]] && [[ "$(cat "$LOCK_FILE" 2>/dev/null)" == "$$" ]]; then
    rm -f "$LOCK_FILE"
    rm -f "$STATUS_FILE"
  fi
}

# Only signal ffmpeg; the main loop reaps it so the exit status is preserved.
on_int() {
  if [[ -n "${FFMPEG_PID}" ]] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
    kill -INT "$FFMPEG_PID" 2>/dev/null || true
  fi
}

trap on_int INT TERM
trap cleanup EXIT

cat >"${STAGING}/info.txt" <<EOF
started=$(date --iso-8601=seconds)
host=$(hostname)
mic=${MIC}
mic_description=${MIC_DESC}
sink=${SINK}
sink_description=${SINK_DESC}
monitor=${MONITOR}
monitor_description=${MONITOR_DESC}
note=System volume and routing were not changed. This is a digital tap of the default microphone and of the default speakers/headphones monitor.
mix_note=mixed.flac is the microphone with the speaker signal removed or attenuated, plus the speaker signal, so the remote side is not recorded twice. The method used is in the mix= line.
local_flac=${LOCAL_DEST}
EOF
write_status recording

# Pulse capture at native 48 kHz. Mixed file is built after stop with AEC.
FILTER="\
[0:a]highpass=f=80,aformat=sample_fmts=s16:sample_rates=48000:channel_layouts=mono[mic_out];\
[1:a]aformat=sample_fmts=s16:sample_rates=48000:channel_layouts=stereo[spk_out]"

dur_opts=()
[[ -n "$DURATION" ]] && dur_opts=(-t "$DURATION")

FFMPEG_ARGS=(
  ffmpeg -hide_banner -nostdin -flush_packets 1
  -thread_queue_size 4096
  "${dur_opts[@]}"
  -f pulse -name "Call recorder" -stream_name "microphone"
  -sample_rate 48000 -channels 2 -i "$MIC"
  -thread_queue_size 4096
  "${dur_opts[@]}"
  -f pulse -name "Call recorder" -stream_name "speakers"
  -sample_rate 48000 -channels 2 -i "$MONITOR"
  -filter_complex "$FILTER"
  -map "[mic_out]" "${dur_opts[@]}" -c:a flac -sample_fmt s16 -compression_level 5 "$MIC_FILE"
  -map "[spk_out]" "${dur_opts[@]}" -c:a flac -sample_fmt s16 -compression_level 5 "$SPK_FILE"
)

red() { if [[ "$USE_COLOR" -eq 1 ]]; then tput setaf 1; tput bold; fi; }
grn() { if [[ "$USE_COLOR" -eq 1 ]]; then tput setaf 2; tput bold; fi; }
dim() { if [[ "$USE_COLOR" -eq 1 ]]; then tput dim; fi; }
rst() { if [[ "$USE_COLOR" -eq 1 ]]; then tput sgr0; fi; }

hms() {
  local s="$1"
  printf '%02d:%02d:%02d' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60))
}

file_hsize() {
  local bytes=0
  [[ -f "$1" ]] || { echo "—"; return; }
  bytes="$(stat -c%s "$1" 2>/dev/null || echo 0)"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$bytes"
  else
    echo "${bytes}B"
  fi
}

draw_ui() {
  local elapsed=$(( $(date +%s) - STARTED_EPOCH ))

  if [[ "$USE_COLOR" -eq 1 ]]; then
    tput cup 0 0 2>/dev/null || printf '\033[H'
    tput ed 2>/dev/null || true
  fi

  echo
  echo "  $(red)● RECORDING$(rst)   $(hms "$elapsed")"
  echo
  echo "  Microphone : ${MIC_DESC}"
  echo "  Speakers   : ${SINK_DESC}"
  echo
  echo "  mic.flac       $(file_hsize "$MIC_FILE")"
  echo "  speakers.flac  $(file_hsize "$SPK_FILE")"
  echo
  echo "  $(dim)Writing to ${STAGING}$(rst)"
  echo "  $(dim)FLAC → ${LOCAL_DEST}$(rst)"
  echo "  $(dim)Opus → ${SHARE_FILE}$(rst)"
  echo
  if [[ -n "$DURATION" ]]; then
    echo "  Auto-stop after ${DURATION}s"
  else
    echo "  $(grn)Stop with Ctrl+C$(rst)"
  fi
  echo
}

if [[ "$USE_COLOR" -eq 1 ]]; then
  tput civis 2>/dev/null || true
  clear
fi

if [[ "$HEADLESS" -eq 0 && -t 1 ]]; then
  notify "Recording" "Mic + speakers. Ctrl+C in the terminal to stop."
fi

set +e
"${FFMPEG_ARGS[@]}" >"$FFMPEG_LOG" 2>&1 &
FFMPEG_PID=$!
set -e

if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
  wait "$FFMPEG_PID" || true
  restore_cursor
  echo "ffmpeg failed to start. Log:" >&2
  cat "$FFMPEG_LOG" >&2
  exit 1
fi

while kill -0 "$FFMPEG_PID" 2>/dev/null; do
  if [[ "$HEADLESS" -eq 0 && -t 1 ]]; then
    draw_ui
  fi
  sleep 1 || true
done

set +e
wait "$FFMPEG_PID"
FFMPEG_STATUS=$?
set -e
FFMPEG_PID=""

restore_cursor
[[ "$USE_COLOR" -eq 1 ]] && clear || true

# ffmpeg exits 255 on SIGINT after a graceful stop; that is success for us.
if [[ "$FFMPEG_STATUS" -ne 0 && "$FFMPEG_STATUS" -ne 255 ]]; then
  echo "Recording failed (ffmpeg exit ${FFMPEG_STATUS}). Log:" >&2
  cat "$FFMPEG_LOG" >&2
  notify "Recording failed" "${FFMPEG_LOG}"
  if [[ -t 0 ]]; then
    echo
    read -r -p "Press Enter to close..."
  fi
  exit 1
fi

ENDED="$(date --iso-8601=seconds)"
ELAPSED=$(( $(date +%s) - STARTED_EPOCH ))
{
  echo "ended=${ENDED}"
  echo "elapsed_seconds=${ELAPSED}"
  echo "ffmpeg_exit=${FFMPEG_STATUS}"
} >>"${STAGING}/info.txt"

write_status encoding

build_mixed() {
  if python3 "${HERE}/aec_mix.py" "$MIC_FILE" "$SPK_FILE" "$MIXED"; then
    echo "mix=speex_aec" >>"${STAGING}/info.txt"
    return 0
  fi
  echo "AEC mix failed, falling back to speaker-ducked mix." >&2
  ffmpeg -hide_banner -nostdin -v error -y -i "$MIC_FILE" -i "$SPK_FILE" \
    -filter_complex "\
[0:a]highpass=f=80,aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=mono[mic];\
[1:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=mono,asplit=2[spk][sc];\
[mic][sc]sidechaincompress=threshold=0.04:ratio=10:attack=8:release=250:knee=8[ducked];\
[ducked][spk]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,alimiter=limit=0.95[mix]" \
    -map "[mix]" -c:a flac -sample_fmt s16 "$MIXED" || return 1
  echo "mix=sidechain_duck" >>"${STAGING}/info.txt"
}

encode_opus() {
  local src="$1" dst="$2"
  ffmpeg -hide_banner -nostdin -v error -y -i "$src" \
    -c:a libopus -b:a 48k -vbr on -compression_level 10 -application voip \
    "$dst"
}

set +e
build_mixed
MIX_STATUS=$?
set -e
if [[ "$MIX_STATUS" -ne 0 || ! -s "$MIXED" ]]; then
  echo "Could not build mixed track." >&2
  notify "Recording failed" "Could not mix mic and speakers."
  exit 1
fi

encode_opus "$MIXED" "${STAGING}/mixed.opus"

mkdir -p "$LOCAL_DEST"

if [[ "$STAGING" != "$LOCAL_DEST" ]]; then
  mv "$MIC_FILE" "$SPK_FILE" "$MIXED" "$FFMPEG_LOG" "${STAGING}/info.txt" "$LOCAL_DEST/"
fi

# The Opus goes to the share folder only if one is configured, is not the
# local folder itself, and can be written; otherwise it stays with the FLAC.
if [[ -n "$SHARE_ROOT" ]]; then
  if ! mkdir -p "$SHARE_ROOT" 2>/dev/null; then
    echo "Cannot create share folder ${SHARE_ROOT}; keeping the Opus with the FLAC files." >&2
    SHARE_FILE="${LOCAL_DEST}/mixed.opus"
  elif [[ "$(readlink -f "$LOCAL_ROOT")" == "$(readlink -f "$SHARE_ROOT")" ]]; then
    SHARE_FILE="${LOCAL_DEST}/mixed.opus"
  fi
fi
if ! mv "${STAGING}/mixed.opus" "$SHARE_FILE" 2>/dev/null; then
  echo "Cannot write ${SHARE_FILE}; keeping the Opus with the FLAC files." >&2
  SHARE_FILE="${LOCAL_DEST}/mixed.opus"
  mv "${STAGING}/mixed.opus" "$SHARE_FILE"
fi
echo "opus=${SHARE_FILE}" >>"${LOCAL_DEST}/info.txt"
rmdir "$STAGING" 2>/dev/null || true

write_status saved

echo
echo "  $(grn)Saved$(rst)  $(hms "$ELAPSED")"
echo
echo "  FLAC  ${LOCAL_DEST}"
echo "  Opus  ${SHARE_FILE}"
echo
if [[ -d "$LOCAL_DEST" ]]; then
  for f in mixed.flac mic.flac speakers.flac; do
    printf "  %-16s %s\n" "$f" "$(file_hsize "$LOCAL_DEST/$f")"
  done
fi
printf "  %-16s %s\n" "$(basename "$SHARE_FILE")" "$(file_hsize "$SHARE_FILE")"
echo
echo "  The Opus file is the one to transcribe or share; the FLAC tracks are the full-quality originals."
echo

notify "Recording saved" "${SHARE_FILE}"

if [[ "$HEADLESS" -eq 0 && -t 0 && -z "$DURATION" ]]; then
  read -r -p "  Press Enter to close..."
fi
