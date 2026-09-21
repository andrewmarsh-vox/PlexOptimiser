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
CUR_MUSIC="$STATE/current-music.json"  # what the audio worker is on right now
CUR_MUSIC_PROG="$STATE/current-music.progress"  # ffmpeg -progress for the bar
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

# House target for music. 320 = MP3-320 CBR. Set MUSIC_DOWNCONVERT=1 to enforce it
# on files that are currently BETTER (lossless) — this deletes the lossless original.
MUSIC_DOWNCONVERT="${MUSIC_DOWNCONVERT:-0}"
MUSIC_TARGET_KBPS="${MUSIC_TARGET_KBPS:-320}"

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
  rm -f "$CUR_MUSIC" "$CUR_MUSIC_PROG" 2>/dev/null
  log "interrupted (signal/exit rc=$rc) - telemetry cleared"
  exit $rc
}
trap _music_cleanup INT TERM HUP
acodec(){ ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1 | tr -d ' '; }
dur(){ ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null | cut -d. -f1; }

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
  if nice -n 15 ffmpeg -nostdin -hide_banner -loglevel error -y -progress "$CUR_MUSIC_PROG" -i "$f" \
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
down=0; saved=0
if [ "$MUSIC_DOWNCONVERT" = 1 ] && [ "$DRY" = 0 ]; then
  while IFS=$'\t' read -r d det sz p; do
    [ "$d" = CONVERT ] || continue
    case "$det" in audio:*) ;; *) continue ;; esac
    [ -f "$p" ] || continue
    excluded "$p" && continue
    osz=$(stat -c%s "$p" 2>/dev/null || echo 0)
    if to_mp3 "$p" "${det%%->*}"; then
      down=$((down+1))
      nsz=$(stat -c%s "${p%.*}.mp3" 2>/dev/null || echo 0)
      saved=$(( saved + osz - nsz ))
    fi
  done < "$PLAN_TSV"
  log "downconvert: $down file(s) -> mp3-${MUSIC_TARGET_KBPS}, reclaimed $((saved/1000000))MB"
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
rm -f "$CUR_MUSIC" "$CUR_MUSIC_PROG"
log "=== Ruby music pass complete ==="
