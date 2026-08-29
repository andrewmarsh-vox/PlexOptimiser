#!/usr/bin/env bash
# Ruby - Plex Optimiser : MUSIC optimiser  (by Andrew Marsh)
#
# CPU-ONLY (no GPU audio codec exists) — runs happily alongside video encodes.
#   1) Compatibility: convert client-INCOMPATIBLE audio codecs (APE/WMA/WavPack/…)
#      to FLAC, losslessly, verify-then-replace. Leaves MP3/AAC/FLAC/Opus/Vorbis alone.
#   2) ReplayGain 2.0 (EBU R128) loudness tags via rsgain — album-aware, non-destructive,
#      skips already-tagged files. (Plexamp also does loudness natively; this also helps
#      plain Plex clients and other players.)
# Low priority (nice 15) so it never disturbs Plex or the video encoder.
set -uo pipefail
ROOT="${MUSIC_ROOT:-/mnt/music}"
LOG="${MUSIC_LOG:-/home/naboo/ruby/music.log}"
STATE="/home/naboo/ruby/state"; DONE="$STATE/music-flac.done"
INCOMPAT="ape wmav1 wmav2 wmalossless wmapro tak tta wavpack musepack mpc als shorten optimfrog"
mkdir -p "$STATE"; touch "$DONE"
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
acodec(){ ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1 | tr -d ' '; }
dur(){ ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null | cut -d. -f1; }

[ -d "$ROOT" ] || { log "no music root $ROOT — nothing to do"; exit 0; }
log "=== Ruby music pass start ($ROOT) ==="

# 1) incompatible audio codec -> FLAC (lossless), verify-then-replace
conv=0
while IFS= read -r -d '' f; do
  c="$(acodec "$f")"; bad=0
  for x in $INCOMPAT; do [ "$c" = "$x" ] && bad=1; done
  [ "$bad" = 1 ] || continue
  od="$(dur "$f")"; base="${f%.*}"; tmp="${base}.ruby.flac"
  log "CONVERT($c->flac): ${f##*/}"
  if nice -n 15 ffmpeg -nostdin -hide_banner -loglevel error -y -i "$f" \
        -map 0:a -c:a flac -compression_level 8 -map_metadata 0 "$tmp" 2>>"$LOG"; then
    nc="$(acodec "$tmp")"; nd="$(dur "$tmp")"; dd=$(( ${od:-0}-${nd:-0} )); dd=${dd#-}
    if [ "$nc" = flac ] && [ "$(stat -c%s "$tmp" 2>/dev/null||echo 0)" -gt 1000 ] && [ "$dd" -le 2 ]; then
      mv -f "$tmp" "${base}.flac"; [ "$f" != "${base}.flac" ] && rm -f "$f"
      echo "${base}.flac">>"$DONE"; conv=$((conv+1)); log "  -> ${base##*/}.flac OK"
    else log "  FAIL(verify) nc=$nc dur_diff=${dd}s"; rm -f "$tmp"; fi
  else log "  FAIL(ffmpeg)"; rm -f "$tmp"; fi
done < <(find "$ROOT" -type f \( -iname '*.ape' -o -iname '*.wma' -o -iname '*.wv' \
         -o -iname '*.tak' -o -iname '*.tta' -o -iname '*.mpc' -o -iname '*.als' \
         -o -iname '*.shn' -o -iname '*.ofr' \) -print0 2>/dev/null)
log "compatibility: $conv file(s) converted to FLAC"

# 2) ReplayGain 2.0 loudness tags (album-aware, skip already-tagged)
if command -v rsgain >/dev/null 2>&1; then
  log "ReplayGain (rsgain easy, skip-existing)…"
  nice -n 15 rsgain easy -S "$ROOT" >>"$LOG" 2>&1 && log "ReplayGain done" || log "rsgain non-zero (some files may lack tags)"
else
  log "rsgain not installed — ReplayGain skipped"
fi
# 3) status summary for the dashboard: per track, is it "good" (compatible format
#    AND already loudness-tagged) or does it still need convert / leveling?
log "scanning track status (format + ReplayGain)…"
total=0; good=0; needconv=0; needgain=0
while IFS= read -r -d '' f; do
  total=$((total+1)); ext="${f##*.}"; ext="${ext,,}"
  case "$ext" in
    ape|wma|wv|tak|tta|mpc|als|shn|ofr) needconv=$((needconv+1)); continue ;;
  esac
  rg="$(ffprobe -v error -show_entries format_tags -of default=nw=1 "$f" 2>/dev/null | grep -iE 'replaygain|r128' | head -1)"
  if [ -n "$rg" ]; then good=$((good+1)); else needgain=$((needgain+1)); fi
done < <(find "$ROOT" -type f \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' \
         -o -iname '*.aac' -o -iname '*.opus' -o -iname '*.ogg' -o -iname '*.wma' \
         -o -iname '*.ape' -o -iname '*.wv' -o -iname '*.wav' -o -iname '*.aiff' \
         -o -iname '*.tak' -o -iname '*.tta' -o -iname '*.mpc' \) -print0 2>/dev/null)
printf '{"total":%d,"good":%d,"need_convert":%d,"need_gain":%d,"ts":%d}\n' \
  "$total" "$good" "$needconv" "$needgain" "$(date +%s)" > "$STATE/music-status.json"
log "status: $good good / $needgain need leveling / $needconv need convert (of $total)"
log "=== Ruby music pass complete ==="
