#!/usr/bin/env bash
# Ruby - Plex Optimiser : MUSIC optimiser  (by Andrew Marsh)
#
# CPU-ONLY (no GPU audio codec exists) — runs happily alongside video encodes.
#   1) Compatibility: convert client-INCOMPATIBLE audio codecs (APE/WMA/WavPack/…)
#      to the house target format, verify-then-replace.
#   2) Downconvert: bring anything BETTER than the house target (FLAC/ALAC/24bit)
#      down to it. Lossy and irreversible — gated behind MUSIC_DOWNCONVERT=1.
#   3) ReplayGain 2.0 (EBU R128) loudness tags via rsgain — album-aware, non-destructive.
# Low priority (nice 15) so it never disturbs Plex or the video encoder.
#
# Flags: --dry-run   report what would change, touch nothing
set -uo pipefail

CONF="${RUBY_CONF:-/home/naboo/ruby/ruby.conf}"
# caller-set env vars win over ruby.conf (lets you dry-run without editing conf)
_env_dc="${MUSIC_DOWNCONVERT:-}"; _env_kb="${MUSIC_TARGET_KBPS:-}"
[ -r "$CONF" ] && . "$CONF"
[ -n "$_env_dc" ] && MUSIC_DOWNCONVERT="$_env_dc"
[ -n "$_env_kb" ] && MUSIC_TARGET_KBPS="$_env_kb"

# Canonicalise: /mnt/music is a symlink, but Plex (and ruby.sh) record realpaths in
# plan.tsv. Writing symlink paths there makes the library panel fail to match.
ROOT="$(readlink -f "${MUSIC_ROOT:-/mnt/music}" 2>/dev/null || echo "${MUSIC_ROOT:-/mnt/music}")"
LOG="${MUSIC_LOG:-/home/naboo/ruby/music.log}"
STATE="/home/naboo/ruby/state"; DONE="$STATE/music-flac.done"
PLAN_TSV="$STATE/plan.tsv"          # the optimiser queue the dashboard renders
DONE_LIST="$STATE/done.list"        # optimiser resume marker
STATS_TSV="$STATE/converted.tsv"    # durable per-file savings record
# Per-worker telemetry. With MUSIC_JOBS>1 several encoders run at once, so each
# writes its own slot (keyed by subshell PID) - a single shared progress file would
# interleave ffmpeg output from every worker and make the bar jump.
CUR_MUSIC_DIR="$STATE/music-current"; mkdir -p "$CUR_MUSIC_DIR"
rm -f "$CUR_MUSIC_DIR"/*.json "$CUR_MUSIC_DIR"/*.progress 2>/dev/null
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

# House target for music. 320 = MP3-320 CBR. Set MUSIC_DOWNCONVERT=1 to enforce it
# on files that are currently BETTER (lossless) — this deletes the lossless original.
MUSIC_DOWNCONVERT="${MUSIC_DOWNCONVERT:-0}"
MUSIC_TARGET_KBPS="${MUSIC_TARGET_KBPS:-320}"
# Parallel encodes. Measured on this N100 (4 cores, while the video encoder was
# running): 1 job = 5221ms/track, 2 = 3502ms (1.49x), 3 = 3396ms, 4 = 3132ms.
# Nearly all the win is in the first extra job, so 2 is the default - higher
# values mostly add IO contention and steal cores from Plex.
# Ceiling on parallel encoders. Because niced time counts as reclaimable headroom,
# the governor will ramp to this whenever nothing at normal priority is competing -
# so the ceiling, not the step logic, is the real control. Default to cores-1 to
# leave one core for Plex, the OS and the video encoder's CPU side.
MUSIC_JOBS="${MUSIC_JOBS:-$(( $(nproc 2>/dev/null || echo 2) - 1 ))}"
[ "$MUSIC_JOBS" -lt 1 ] && MUSIC_JOBS=1

INCOMPAT="ape wmav1 wmav2 wmalossless wmapro tak tta wavpack musepack mpc als shorten optimfrog"
LOSSLESS="flac alac ape wavpack tak tta wmalossless shorten optimfrog pcm_s16le pcm_s24le pcm_s32le"
mkdir -p "$STATE"; touch "$DONE" "$PLAN_TSV" "$DONE_LIST" "$STATS_TSV"
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# Clean shutdown: never leave a partial .ruby.mp3 beside the source, and never leave
# stale "now converting" telemetry behind for the dashboard.
RUBY_MUSIC_TMP=""
_music_cleanup(){
  local rc=$?
  [ -n "${RUBY_MUSIC_TMP:-}" ] && rm -f "$RUBY_MUSIC_TMP" 2>/dev/null
  rm -f "$CUR_MUSIC_DIR"/*.json "$CUR_MUSIC_DIR"/*.progress 2>/dev/null
  log "interrupted (signal/exit rc=$rc) - telemetry cleared"
  exit $rc
}
trap _music_cleanup INT TERM HUP
acodec(){ ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1 | tr -d ' '; }
dur(){ ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null | cut -d. -f1; }

# Converting a file replaces track.flac with track.mp3 and deletes the original, so
# every library that indexed the old path now points at a file that is gone. Lidarr
# keeps reporting the stale .flac and its "what I have" counts drift; Plex shows the
# track as missing until it rescans. Both must be told.
LIDARR_URL="${LIDARR_URL:-http://127.0.0.1:8686}"
LIDARR_CFG="${LIDARR_CFG:-/root/media-stack/config/lidarr/config.xml}"
LIDARR_KEY="${LIDARR_KEY:-$(grep -oP '(?<=<ApiKey>)[^<]+' "$LIDARR_CFG" 2>/dev/null)}"
PLEX_URL="${PLEX_URL:-http://127.0.0.1:32400}"
PLEX_SECRETS="${PLEX_SECRETS:-/root/media-stack/homeassistant/secrets.yaml}"
PLEX_TOKEN="${PLEX_TOKEN:-$(grep -oP 'plex_token:\s*\K\S+' "$PLEX_SECRETS" 2>/dev/null)}"
NOTIFY_PENDING=0

# Rescan is expensive, so we do not fire per file: mark dirty and flush once the
# pass ends (or every NOTIFY_EVERY conversions for long runs).
NOTIFY_EVERY="${NOTIFY_EVERY:-200}"
notify_mark(){ NOTIFY_PENDING=$((NOTIFY_PENDING+1)); }
notify_flush(){
  [ "$NOTIFY_PENDING" -gt 0 ] || return 0
  if [ -n "$LIDARR_KEY" ]; then
    if curl -sf -m 10 -X POST -H "X-Api-Key: $LIDARR_KEY" -H 'Content-Type: application/json' \
         "$LIDARR_URL/api/v1/command" -d '{"name":"RescanFolders"}' -o /dev/null 2>/dev/null; then
      log "lidarr: RescanFolders queued after $NOTIFY_PENDING conversion(s)"
    else
      log "lidarr: rescan request failed (non-fatal)"
    fi
  else
    log "lidarr: no API key found, rescan skipped"
  fi
  if [ -n "$PLEX_TOKEN" ]; then
    local sect
    sect=$(curl -sf -m 10 "$PLEX_URL/library/sections?X-Plex-Token=$PLEX_TOKEN" 2>/dev/null \
           | grep -oP '<Directory[^>]*type="artist"[^>]*key="\K[0-9]+' | head -n1)
    if [ -n "$sect" ] && curl -sf -m 10 "$PLEX_URL/library/sections/$sect/refresh?X-Plex-Token=$PLEX_TOKEN" -o /dev/null 2>/dev/null; then
      log "plex: music section $sect refresh queued"
    fi
  fi
  NOTIFY_PENDING=0
}

# Never touch anything under an excluded root (irreplaceable personal media).
excluded(){
  local p="$1" r
  for r in "${EXCLUDE_ROOTS[@]:-}"; do
    [ -n "$r" ] && case "$p" in "$r"/*|"$r") return 0 ;; esac
  done
  return 1
}

[ -e "$ROOT" ] || { log "no music root $ROOT — nothing to do"; exit 0; }
log "=== Ruby music pass start ($ROOT)$([ "$DRY" = 1 ] && echo ' [DRY RUN]') ==="
log "target: MP3-${MUSIC_TARGET_KBPS}  downconvert_lossless=${MUSIC_DOWNCONVERT}"

# Encode $1 -> mp3 at target bitrate, verify, replace. Returns 0 on success.
to_mp3(){
  local f="$1" why="$2"
  local od base tmp nc nd dd osz nsz
  local CUR_MUSIC="$CUR_MUSIC_DIR/$BASHPID.json"
  local CUR_MUSIC_PROG="$CUR_MUSIC_DIR/$BASHPID.progress"
  od="$(dur "$f")"; base="${f%.*}"; tmp="${base}.ruby.mp3"
  RUBY_MUSIC_TMP="$tmp"
  osz=$(stat -c%s "$f" 2>/dev/null || echo 0)
  if [ "$DRY" = 1 ]; then
    log "  WOULD CONVERT($why): ${f##*/}  ($((osz/1000000))MB)"
    return 0
  fi
  log "CONVERT($why -> mp3-${MUSIC_TARGET_KBPS}): ${f##*/}"
  printf '{"src":"%s","base":"%s","size":%s,"duration":%s,"why":"%s","start":%s}\n' \
    "${f//\"/}" "${f##*/}" "${osz:-0}" "${od:-0}" "${why//\"/}" "$(date +%s)" > "$CUR_MUSIC"
  : > "$CUR_MUSIC_PROG"
  # Carry embedded cover art across (FLAC PICTURE -> ID3 APIC). Mapping audio alone
  # silently stripped it from every converted album. If the art stream can't be
  # muxed into MP3, retry audio-only rather than fail the track.
  if nice -n 15 ffmpeg -nostdin -hide_banner -loglevel error -y -progress "$CUR_MUSIC_PROG" -i "$f" \
        -map 0:a:0 -c:a libmp3lame -b:a "${MUSIC_TARGET_KBPS}k" \
        -map '0:v:0?' -c:v copy -disposition:v:0 attached_pic \
        -map_metadata 0 -id3v2_version 3 -write_id3v1 1 "$tmp" 2>>"$LOG" \
     || nice -n 15 ffmpeg -nostdin -hide_banner -loglevel error -y -progress "$CUR_MUSIC_PROG" -i "$f" \
        -map 0:a:0 -c:a libmp3lame -b:a "${MUSIC_TARGET_KBPS}k" \
        -map_metadata 0 -id3v2_version 3 -write_id3v1 1 "$tmp" 2>>"$LOG"; then
    nc="$(acodec "$tmp")"; nd="$(dur "$tmp")"
    dd=$(( ${od:-0}-${nd:-0} )); dd=${dd#-}
    nsz=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
    if [ "$nc" = mp3 ] && [ "$nsz" -gt 1000 ] && [ "$dd" -le 2 ]; then
      mv -f "$tmp" "${base}.mp3"
      [ "$f" != "${base}.mp3" ] && rm -f "$f"
      echo "${base}.mp3" >> "$DONE"
      echo "${base}.mp3" >> "$DONE_LIST"
      [ "$f" != "${base}.mp3" ] && echo "$f" >> "$DONE_LIST"   # source path: dedup + dashboard
      printf '%s\taudio\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$osz" "$nsz" "$((osz-nsz))" "${base}.mp3" >> "$STATS_TSV"
      log "  -> ${base##*/}.mp3 OK  ($((osz/1000000))MB -> $((nsz/1000000))MB)"
      RUBY_MUSIC_TMP=""; rm -f "$CUR_MUSIC" "$CUR_MUSIC_PROG"; return 0
    else
      log "  FAIL(verify) nc=$nc dur_diff=${dd}s size=$nsz"; rm -f "$tmp" "$CUR_MUSIC" "$CUR_MUSIC_PROG"; return 1
    fi
  else
    log "  FAIL(ffmpeg)"; rm -f "$tmp" "$CUR_MUSIC" "$CUR_MUSIC_PROG"; return 1
  fi
}

# ---- 1) incompatible codecs -> target format -------------------------------
conv=0
while IFS= read -r -d '' f; do
  excluded "$f" && continue
  c="$(acodec "$f")"; bad=0
  for x in $INCOMPAT; do [ "$c" = "$x" ] && bad=1; done
  [ "$bad" = 1 ] || continue
  to_mp3 "$f" "incompatible:$c" && conv=$((conv+1))
done < <(find -L "$ROOT" -type f \( -iname '*.ape' -o -iname '*.wma' -o -iname '*.wv' \
         -o -iname '*.tak' -o -iname '*.tta' -o -iname '*.mpc' -o -iname '*.als' \
         -o -iname '*.shn' -o -iname '*.ofr' \) -print0 2>/dev/null)
log "compatibility: $conv file(s) converted"
[ "$conv" -gt 0 ] && { NOTIFY_PENDING=$conv; notify_flush; }

# ---- 2) queue anything BETTER than target into the optimiser's own plan -----
# We do not keep a separate music work list: candidates are appended to state/plan.tsv
# as ordinary CONVERT rows, so they appear in the dashboard queue alongside video work.
queued=0
declare -A inplan
while IFS=$'\t' read -r _d _det _sz _p; do
  [ -n "${_p:-}" ] && inplan["$_p"]=1
done < "$PLAN_TSV"
while IFS= read -r -d '' f; do
  excluded "$f" && continue
  [ -n "${inplan["$f"]:-}" ] && continue
  grep -qxF "$f" "$DONE_LIST" 2>/dev/null && continue
  c="$(acodec "$f")"; hit=0
  for x in $LOSSLESS; do [ "$c" = "$x" ] && hit=1; done
  [ "$hit" = 1 ] || continue
  sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
  if [ "$DRY" = 1 ]; then
    log "  WOULD QUEUE($c): ${f##*/} ($((sz/1000000))MB)"
  else
    printf 'CONVERT\taudio:%s->mp3-%s\t%s\t%s\n' "$c" "$MUSIC_TARGET_KBPS" "$sz" "$f" >> "$PLAN_TSV"
    inplan["$f"]=1
  fi
  queued=$((queued+1))
done < <(find -L "$ROOT" -type f \( -iname '*.flac' -o -iname '*.m4a' -o -iname '*.alac' \
         -o -iname '*.wav' -o -iname '*.aiff' -o -iname '*.aif' \) -print0 2>/dev/null)
log "queued: $queued file(s) added to optimiser plan ($PLAN_TSV)"

# ---- 2b) work the queue (only when downconvert is switched on) --------------
# How many encodes to run at once, given what else the box is doing right now.
# Audio is CPU-only (no GPU audio codec exists), so it competes with Plex
# TRANSCODES and with ffmpeg's CPU side - never with the VAAPI video encode.
# Closed-loop parallelism, in the same spirit as the GPU governor: measure, then
# step ONE job up if there is headroom or one down if there is not, rather than
# flipping between 1 and max.
#
# loadavg is the wrong signal here. It counts uninterruptible (D-state) IO waiters,
# and this box sits around 45% iowait while the video encoder copies output to the
# array - loadavg reads >4 on 4 cores while the CPU is largely idle. We sample
# /proc/stat for real idle/iowait instead.
AUDIO_JOBS_CUR=1
AUDIO_LAST_EVAL=0
AUDIO_EVAL_SEC="${AUDIO_EVAL_SEC:-15}"      # re-measure at most this often
AUDIO_IDLE_UP="${AUDIO_IDLE_UP:-25}"        # idle% above which we add an encoder
AUDIO_IDLE_DOWN="${AUDIO_IDLE_DOWN:-10}"    # idle% below which we drop one
AUDIO_IOWAIT_CEIL="${AUDIO_IOWAIT_CEIL:-55}" # iowait% above which more jobs cannot help

cpu_sample(){   # -> "idle_pct iowait_pct" sampled over $1 seconds
  local s1 s2
  s1=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5, $6}' /proc/stat 2>/dev/null)
  sleep "${1:-1}"
  s2=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5, $6}' /proc/stat 2>/dev/null)
  awk -v a="$s1" -v b="$s2" 'BEGIN{
    split(a,x," "); split(b,y," ");
    dt = y[1]-x[1];
    if (dt <= 0) { print "0 100"; exit }
    printf "%d %d", (y[2]-x[2])*100/dt, (y[3]-x[3])*100/dt
  }'
}

# Share of CPU spent on NICED work over $1 seconds. This is load we can preempt:
# our own encoders run at nice 15-19, so it is headroom, not contention.
cpu_nice_pct(){
  local s1 s2
  s1=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $3}' /proc/stat 2>/dev/null)
  sleep "${1:-1}"
  s2=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $3}' /proc/stat 2>/dev/null)
  awk -v a="$s1" -v b="$s2" 'BEGIN{
    split(a,x," "); split(b,y," ");
    dt=y[1]-x[1]; if(dt<=0){print 0; exit}
    printf "%d", (y[2]-x[2])*100/dt
  }'
}

# Only a VIDEO transcode really costs us; an audio-only or direct-play session does
# not. This matches how ruby-governor.sh counts Plex load.
plex_video_transcodes(){
  local x
  x=$(curl -sf -m3 "$PLEX_URL/status/sessions?X-Plex-Token=${PLEX_TOKEN:-}" 2>/dev/null) || { echo 0; return; }
  local n
  n=$(grep -oE '<TranscodeSession [^>]*' <<<"$x" | grep -c 'videoDecision="transcode"' 2>/dev/null | head -n1)
  echo "${n:-0}"
}

audio_jobs_now(){
  local now cores idle iow tx cur max
  now=$(date +%s)
  # Sampling costs a second; at ~3.5s per track that would be ~30% overhead if we
  # measured on every slot. Re-use the last decision inside the eval window.
  if [ $(( now - AUDIO_LAST_EVAL )) -lt "$AUDIO_EVAL_SEC" ]; then
    echo "$AUDIO_JOBS_CUR"; return
  fi
  AUDIO_LAST_EVAL="$now"
  cores=$(nproc 2>/dev/null || echo 2)
  max="$MUSIC_JOBS"; [ "$max" -gt "$cores" ] && max="$cores"; [ "$max" -lt 1 ] && max=1
  cur="$AUDIO_JOBS_CUR"; [ "$cur" -lt 1 ] && cur=1
  tx=$(plex_video_transcodes)
  if [ "${tx:-0}" -gt 0 ]; then
    [ "$cur" -ne 1 ] && log "audio governor: plex transcoding -> 1 encoder (was $cur)" >&2
    AUDIO_JOBS_CUR=1; echo 1; return
  fi
  read -r idle iow <<<"$(cpu_sample 1)"
  # Raw idle is the wrong yardstick on this box. Almost all load here is OUR OWN
  # niced work (nice=69% in a typical sample: the audio encoder at nice 19 and the
  # video encoder's CPU side), which yields instantly to anything at normal priority.
  # Counting it as "no headroom" means we throttle ourselves because we are busy.
  # Treat nice time as reclaimable, like ruby-governor.sh throttles against Plex
  # rather than against total GPU use.
  local nice_pct effective_idle
  nice_pct=$(cpu_nice_pct)
  effective_idle=$(( ${idle:-0} + ${nice_pct:-0} ))
  [ "$effective_idle" -gt 100 ] && effective_idle=100
  local before="$cur"
  idle="$effective_idle"
  if [ "${iow:-0}" -ge "$AUDIO_IOWAIT_CEIL" ]; then
    [ "$cur" -gt 1 ] && cur=$(( cur - 1 ))        # disk-bound: more encoders just queue
  elif [ "${idle:-0}" -ge "$AUDIO_IDLE_UP" ]; then
    [ "$cur" -lt "$max" ] && cur=$(( cur + 1 ))   # headroom: ramp up a step
  elif [ "${idle:-0}" -le "$AUDIO_IDLE_DOWN" ]; then
    [ "$cur" -gt 1 ] && cur=$(( cur - 1 ))        # saturated: back off a step
  fi
  if [ "$cur" != "$before" ]; then
    log "audio governor: idle=${idle}% iowait=${iow}% -> $cur encoder(s) (was $before, max $max)" >&2
  fi
  AUDIO_JOBS_CUR="$cur"
  printf '{"jobs":%s,"max":%s,"idle":%s,"nice":%s,"iowait":%s,"plex_tx":%s,"ts":%s}\n' \
    "$cur" "$max" "${idle:-0}" "${nice_pct:-0}" "${iow:-0}" "${tx:-0}" "$now" > "$STATE/audio-governor.json" 2>/dev/null
  echo "$cur"
}


down=0; saved=0
if [ "$MUSIC_DOWNCONVERT" = 1 ] && [ "$DRY" = 0 ]; then
  PLEX_TOKEN="${PLEX_TOKEN:-$(grep -oP 'plex_token:\s*\K\S+' /root/media-stack/homeassistant/secrets.yaml 2>/dev/null)}"
  # HARD SAFETY: a non-integer here makes `[ n -ge $JOBS ]` error, the pool guard
  # never blocks, and every queue row spawns an encoder - a fork bomb (this happened:
  # load hit 227 when a log line leaked into the captured value). Never trust the
  # governor's output; clamp it to a sane integer before it is used as a limit.
  AUDIO_HARD_MAX="${AUDIO_HARD_MAX:-$(nproc 2>/dev/null || echo 4)}"
  sane_jobs(){  # $1=candidate -> a clamped integer on stdout, never empty
    local v="${1:-}"
    case "$v" in (''|*[!0-9]*) v=1 ;; esac
    [ "$v" -lt 1 ] && v=1
    [ "$v" -gt "$AUDIO_HARD_MAX" ] && v="$AUDIO_HARD_MAX"
    printf '%s' "$v"
  }
  # audio_jobs_now() must be called DIRECTLY, not via $(...): a command substitution
  # runs it in a subshell, so AUDIO_JOBS_CUR never propagates back and the governor
  # restarts from 1 on every call - it could step to 2 and never any higher.
  audio_jobs_now >/dev/null 2>&1
  JOBS=$(sane_jobs "$AUDIO_JOBS_CUR")
  RESULTS="$STATE/.music-results.$$"; : > "$RESULTS"
  log "downconvert: starting with $JOBS parallel encoder(s) (MUSIC_JOBS=$MUSIC_JOBS, $(nproc) cores)"
  while IFS=$'\t' read -r d det sz p; do
    [ "$d" = CONVERT ] || continue
    case "$det" in audio:*) ;; *) continue ;; esac
    [ -f "$p" ] || continue
    excluded "$p" && continue
    (
      osz=$(stat -c%s "$p" 2>/dev/null || echo 0)
      if to_mp3 "$p" "${det%%->*}"; then
        nsz=$(stat -c%s "${p%.*}.mp3" 2>/dev/null || echo 0)
        printf '%s\t%s\n' "$osz" "$nsz" >> "$RESULTS"
      fi
    ) &
    # Keep the pool full, and re-evaluate headroom as conditions change.
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do
      wait -n 2>/dev/null || break
      audio_jobs_now >/dev/null 2>&1
      JOBS=$(sane_jobs "$AUDIO_JOBS_CUR")
    done
    # Belt and braces: if the guard above ever fails to block, do not run away.
    while [ "$(jobs -rp | wc -l)" -ge "$AUDIO_HARD_MAX" ]; do
      wait -n 2>/dev/null || break
    done
  done < "$PLAN_TSV"
  wait
  if [ -s "$RESULTS" ]; then
    down=$(grep -c "" "$RESULTS")
    saved=$(awk -F'\t' '{s += $1 - $2} END {printf "%d", s+0}' "$RESULTS")
  fi
  rm -f "$RESULTS"
  log "downconvert: $down file(s) -> mp3-${MUSIC_TARGET_KBPS}, reclaimed $((saved/1000000))MB"
  # Tell Lidarr/Plex the files changed underneath them.
  [ "$down" -gt 0 ] && { NOTIFY_PENDING=$down; notify_flush; }
else
  log "downconvert: not running (MUSIC_DOWNCONVERT=${MUSIC_DOWNCONVERT}, dry=$DRY) - items stay queued"
fi

# ---- 3) ReplayGain ---------------------------------------------------------
if [ "$DRY" = 1 ]; then
  log "ReplayGain skipped (dry run)"
elif command -v rsgain >/dev/null 2>&1; then
  log "ReplayGain (rsgain easy, skip-existing)…"
  nice -n 15 rsgain easy -S "$ROOT/" >>"$LOG" 2>&1 && log "ReplayGain done" || log "rsgain non-zero (some files may lack tags)"
else
  log "rsgain not installed — ReplayGain skipped"
fi

# ---- 4) status summary for the dashboard -----------------------------------
log "scanning track status (format + ReplayGain)…"
total=0; good=0; needconv=0; needgain=0; needdown=0
while IFS= read -r -d '' f; do
  total=$((total+1)); ext="${f##*.}"; ext="${ext,,}"
  case "$ext" in
    ape|wma|wv|tak|tta|mpc|als|shn|ofr) needconv=$((needconv+1)); continue ;;
    flac|wav|aiff|aif) needdown=$((needdown+1)) ;;
  esac
  rg="$(ffprobe -v error -show_entries format_tags -of default=nw=1 "$f" 2>/dev/null | grep -iE 'replaygain|r128' | head -1)"
  if [ -n "$rg" ]; then good=$((good+1)); else needgain=$((needgain+1)); fi
done < <(find -L "$ROOT" -type f \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' \
         -o -iname '*.aac' -o -iname '*.opus' -o -iname '*.ogg' -o -iname '*.wma' \
         -o -iname '*.ape' -o -iname '*.wv' -o -iname '*.wav' -o -iname '*.aiff' \
         -o -iname '*.tak' -o -iname '*.tta' -o -iname '*.mpc' \) -print0 2>/dev/null)
printf '{"total":%d,"good":%d,"need_convert":%d,"need_gain":%d,"need_downconvert":%d,"ts":%d}\n' \
  "$total" "$good" "$needconv" "$needgain" "$needdown" "$(date +%s)" > "$STATE/music-status.json"
log "status: $good good / $needgain need leveling / $needconv need convert / $needdown above target (of $total)"
rm -f "$CUR_MUSIC_DIR"/*.json "$CUR_MUSIC_DIR"/*.progress 2>/dev/null
log "=== Ruby music pass complete ==="
