#!/usr/bin/env bash
# Ruby - Plex Optimiser  —  iGPU feedback governor (by Andrew Marsh)
#
# Closed-loop throttle scaled to real iGPU headroom:
#   * Plex idle (no streams)  -> Ruby runs at 100% (the encode IS the GPU load; saturation is the goal).
#   * Plex active             -> poll the iGPU every GOV_POLL_SEC; if busy% > GOV_GPU_MAX (95) back Ruby
#                                OFF a step, if there's headroom ramp it back UP — keeping total iGPU
#                                under the ceiling so Plex transcoding always has room.
# Throttling is done by duty-cycling Ruby's cgroup (rapid SIGSTOP/SIGCONT, like cpulimit).
# Audio/CPU work is never GPU-bound, so this only governs the video encode.
# Settings live in ruby.conf (web-editable), re-read every cycle.
set -uo pipefail
BASE=/home/naboo/ruby
STATE="$BASE/state"; CONF="$BASE/ruby.conf"; GLOG="$BASE/governor.log"
PLEX_URL="http://127.0.0.1:32400"; SECRETS="/root/media-stack/homeassistant/secrets.yaml"
CG="/sys/fs/cgroup/system.slice/ruby.service/cgroup.procs"
mkdir -p "$STATE"
TOKEN="$(grep -oP 'plex_token:\s*\K\S+' "$SECRETS" 2>/dev/null)"
RC6F=""; for c in /sys/class/drm/card1/gt/gt0/rc6_residency_ms /sys/class/drm/card0/gt/gt0/rc6_residency_ms; do [ -r "$c" ] && { RC6F="$c"; break; }; done

plex_sessions(){ curl -sf -m4 "$PLEX_URL/status/sessions?X-Plex-Token=$TOKEN" 2>/dev/null; }
# Total sessions (display only) and sessions that actually cost the server GPU/CPU.
# Direct play costs nothing: only a video TRANSCODE uses the iGPU, which is what Ruby competes with.
plex_counts(){ local x n_all n_tx
  x=$(plex_sessions) || { echo "0 0"; return; }
  [ -z "$x" ] && { echo "0 0"; return; }
  n_all=$(grep -oE '<(Video|Track|Photo) ' <<<"$x" | wc -l)
  n_tx=$(grep -oE '<TranscodeSession [^>]*' <<<"$x" | grep -c 'videoDecision="transcode"')
  echo "$n_all $n_tx"; }
ruby_pids(){ [ -r "$CG" ] && tr '\n' ' ' < "$CG"; }
cont(){ [ -n "$1" ] && kill -CONT $1 2>/dev/null; }
stop(){ [ -n "$1" ] && kill -STOP $1 2>/dev/null; }
write_state(){ printf '{"enabled":%s,"target_pct":%s,"gpu_busy":%s,"plex_streams":%s,"reason":"%s","ts":%s,"plex_transcodes":%s}\n' \
    "$1" "$2" "$3" "$4" "$5" "$(date +%s)" "${6:-0}" > "$STATE/governor.json.tmp" && mv -f "$STATE/governor.json.tmp" "$STATE/governor.json"; }

prev_rc6=$([ -n "$RC6F" ] && cat "$RC6F" 2>/dev/null || echo 0); prev_ms=$(date +%s%3N)
target=100; last_log=""
while true; do
  GOV_ENABLED=1; GOV_POLL_SEC=5; GOV_NICE_IDLE=0; GOV_GPU_MAX=95; GOV_MIN_PCT=10
  GOV_STEP_DOWN=20; GOV_STEP_UP=10; GOV_PERIOD_MS=1000
  # shellcheck disable=SC1090
  [ -r "$CONF" ] && . "$CONF" 2>/dev/null

  # measure average iGPU busy% over the previous cycle (RC6 = cumulative idle ms)
  rc6=$([ -n "$RC6F" ] && cat "$RC6F" 2>/dev/null || echo 0); nowms=$(date +%s%3N)
  busy=$(awk -v r="$rc6" -v pr="$prev_rc6" -v n="$nowms" -v pn="$prev_ms" 'BEGIN{d=n-pn; if(d<=0||r<pr){print -1;exit} b=100-100*(r-pr)/d; if(b<0)b=0; if(b>100)b=100; printf "%d",b}')
  prev_rc6=$rc6; prev_ms=$nowms
  read -r streams streams_tx <<<"$(plex_counts)"

  if [ "${GOV_ENABLED:-1}" != 1 ]; then target=100; reason="governor-off"
  elif [ "${streams_tx:-0}" -eq 0 ]; then target=100; reason="idle-full (${streams:-0} direct play, no transcode)"
  else
    if   [ "$busy" -lt 0 ]; then reason="measuring (${busy})"
    elif [ "$busy" -gt "$GOV_GPU_MAX" ]; then target=$((target-GOV_STEP_DOWN)); reason="gpu ${busy}% > ${GOV_GPU_MAX}% — backing off"
    elif [ "$busy" -lt $((GOV_GPU_MAX-10)) ]; then target=$((target+GOV_STEP_UP)); reason="gpu ${busy}% — headroom, ramping"
    else reason="gpu ${busy}% — holding"; fi
    [ "$target" -lt "$GOV_MIN_PCT" ] && target=$GOV_MIN_PCT
    [ "$target" -gt 100 ] && target=100
  fi

  if [ "$reason|$target" != "$last_log" ]; then echo "[$(date '+%F %T')] target=${target}% ($reason; plex streams=$streams, transcodes=${streams_tx:-0})" >> "$GLOG"; last_log="$reason|$target"; fi
  write_state "${GOV_ENABLED:-1}" "$target" "$busy" "${streams:-0}" "$reason" "${streams_tx:-0}"

  pids="$(ruby_pids)"
  nice_now=10; [ "$target" -ge 100 ] && nice_now="${GOV_NICE_IDLE:-0}"
  [ -n "$pids" ] && renice -n "$nice_now" $pids >/dev/null 2>&1

  if [ -z "$pids" ] || [ "$target" -ge 100 ]; then
    cont "$pids"; sleep "${GOV_POLL_SEC:-5}"
  else
    period=$(awk "BEGIN{print ${GOV_PERIOD_MS:-1000}/1000}")
    on=$(awk "BEGIN{printf \"%.3f\", $period*$target/100}")
    off=$(awk "BEGIN{printf \"%.3f\", $period-($period*$target/100)}")
    end=$(( $(date +%s) + ${GOV_POLL_SEC:-5} ))
    while [ "$(date +%s)" -lt "$end" ]; do
      pids="$(ruby_pids)"; [ -z "$pids" ] && break
      cont "$pids"; sleep "$on"; stop "$pids"; sleep "$off"
    done
    cont "$(ruby_pids)"
  fi
done
