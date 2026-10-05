#!/usr/bin/env bash
#
#  ____            _              ____  _             ___        _   _           _
# |  _ \ _   _ ___| |__  _   _   |  _ \| | _____  __ / _ \ _ __ | |_(_)_ __ ___ (_)___  ___ _ __
# | |_) | | | | _ \ '_ \| | | |  | |_) | |/ _ \ \/ /| | | | '_ \| __| | '_ ` _ \| / __|/ _ \ '__|
# |  _ <| |_| |  _ \ |_) | |_| |  |  __/| |  __/>  < | |_| | |_) | |_| | | | | | | \__ \  __/ |
# |_| \_\\__,_|_.__/_.__/ \__, |  |_|   |_|\___/_/\_\ \___/| .__/ \__|_|_| |_| |_|_|___/\___|_|
#                         |___/                            |_|
# Ruby - Plex Optimiser  —  by Andrew Marsh
#
# Optimises a Plex library for DIRECT PLAY (no client transcoding) without dropping
# resolution or quality:
#   * shrinks bloated high-bitrate remuxes to efficient HEVC (Intel QSV/VAAPI),
#   * converts client-incompatible video codecs (VC-1 / MPEG-2 / AV1 / ...) to HEVC,
#   * adds universally-compatible audio (AC3 5.1 + AAC 2.0) alongside the lossless track,
#   * keeps English audio only (untagged tracks kept when nothing is tagged English) and English subtitles,
#   * then tells Plex to re-index each optimised file so its database matches.
#
# Libraries to scan + their Plex section ids are discovered from Plex itself (API key).
# Per file: probe -> (HEVC encode | lossless remux) to NVMe scratch -> verify ->
#           atomic replace -> Plex partial-scan. Original is never deleted until a
#           verified replacement exists. Resumable via state/done.list.
#
set -uo pipefail

############################# CONFIG ##########################################
# Web-dashboard-editable settings (written by dashboard.py via :8800). Sourced
# first so it overrides the ${VAR:-default} fallbacks below.
[ -r /home/naboo/ruby/ruby.conf ] && . /home/naboo/ruby/ruby.conf
# ROOTS is auto-discovered from Plex at runtime (see plex_discover); this is the
# fallback used only if Plex is unreachable. Real dirs, NOT the /mnt/* symlinks —
# find won't descend a symlink given as a start-point. Ordered SHOWS-FIRST so TV
# is optimised before Movies (see discover_libraries + the shows-first main loop).
ROOTS=("/mnt/disks/5TBSeagate/Shows" "/mnt/disks/16TBSeagate/Movies")
# Library roots whose content is TV — capped at 1080p (no 4K on shows). Overwritten
# by discover_libraries with the real show-type Plex library dirs. Fallback = 5TB.
SHOW_ROOTS=("/mnt/disks/5TBSeagate/Shows")
# 1 = downscale any 4K TV episode to 1080p (shows are 1080p at best, 720p otherwise);
# Movies are unaffected and keep 4K. 0 = keep native resolution everywhere.
CAP_SHOWS_1080P="${CAP_SHOWS_1080P:-1}"
# Per-resolution quality standards. The number is the quality target (lower = better):
# it is fed as ICQ for 10-bit sources (HDR/4K) and as CQP for 8-bit sources (SDR 1080p),
# because this iGPU's HEVC encoder only supports ICQ on the 10-bit (Main10) path.
Q_4K="${Q_4K:-24}"               # 4K target quality (balanced)
Q_1080="${Q_1080:-23}"           # 1080p target quality (a touch higher; source is smaller)
MIN_WIDTH_4K="${MIN_WIDTH_4K:-3000}"     # >=3000px wide  -> 4K tier
MIN_WIDTH_1080="${MIN_WIDTH_1080:-1700}" # >=1700px wide  -> 1080p tier (below this = 720p/SD, skipped)
MIN_MBPS_4K="${MIN_MBPS_4K:-28}"         # skip 4K already below this bitrate (already compressed)
MIN_MBPS_1080="${MIN_MBPS_1080:-18}"     # skip 1080p below this (WEB-DL/encodes; only remuxes exceed it)
MIN_SIZE_GB="${MIN_SIZE_GB:-6}"  # pre-filter: ignore files smaller than this (catches 1080p remuxes too)
SCRATCH="${SCRATCH:-/home/naboo/ruby/scratch}"
STATE_DIR="${STATE_DIR:-/home/naboo/ruby/state}"
LOG="${LOG:-/home/naboo/ruby/ruby.log}"
RENDER="${RENDER:-/dev/dri/renderD128}"
DRY_RUN="${DRY_RUN:-0}"
MIN_FREE_GB="${MIN_FREE_GB:-30}" # require this much free on dest drive before replacing
# --- compatibility pass (avoid client transcoding, NOT resolution-related) ---
Q_720="${Q_720:-22}"             # quality for sub-1080p compatibility re-encodes (resolution preserved)
SCAN_MIN_MB="${SCAN_MIN_MB:-500}"  # find floor (MB): probe any file >= this. 500MB catches real TV episodes + movies while skipping tiny samples/featurettes/extras. Set lower (e.g. 1) to check literally everything.
# Library roots Ruby must NEVER touch (irreplaceable media). Prefix match, so listing a
# directory excludes everything beneath it. Paths may contain spaces -> keep it an array.
[ -v EXCLUDE_ROOTS ] || EXCLUDE_ROOTS=()
# Video codecs modern TVs/tablets can't direct-play -> always force to HEVC (any size/bitrate).
BAD_VIDEO="${BAD_VIDEO:-vc1 mpeg2video av1 mpeg4 msmpeg4v3 wmv3 vp6f vp6 rv40}"
# Audio codecs that direct-play on TVs/tablets; if a file has NONE of these we add compatible tracks.
GOOD_AUDIO="${GOOD_AUDIO:-aac ac3 eac3 mp3}"
ADD_AC3="${ADD_AC3:-1}"          # add a Dolby Digital 5.1 track when no TV-friendly audio exists
ADD_AAC="${ADD_AAC:-1}"          # add an AAC 2.0 stereo track  when no TV-friendly audio exists
# Plex notify: after replacing a file, ask Plex to re-scan that folder so its DB
# picks up the NEW codec (HEVC). Without this, Plex keeps the original file's
# codec (vc1/h264) cached and builds a broken transcode -> playback fails.
PLEX_URL="${PLEX_URL:-http://127.0.0.1:32400}"
PLEX_SECRETS="${PLEX_SECRETS:-/root/media-stack/homeassistant/secrets.yaml}"
PLEX_TOKEN="${PLEX_TOKEN:-$(grep -oP 'plex_token:\s*\K\S+' "$PLEX_SECRETS" 2>/dev/null)}"
# real-path-prefix:plex-path-prefix:section-id  (space-separated). Auto-discovered
# from Plex at runtime; this is the fallback used only if Plex is unreachable.
PLEX_PATHMAP="${PLEX_PATHMAP:-/mnt/disks/16TBSeagate/Movies:/mnt/movies:1 /mnt/disks/5TBSeagate/Shows:/mnt/shows:2}"
PLEX_LIB_TYPES="${PLEX_LIB_TYPES:-movie show}"  # which Plex section types Ruby optimises (e.g. "movie" or "movie show")
export LIBVA_DRIVER_NAME=iHD
##############################################################################

mkdir -p "$SCRATCH" "$STATE_DIR" "$(dirname "$LOG")"
DONE_LIST="$STATE_DIR/done.list"; FAIL_LIST="$STATE_DIR/failed.list"
MAX_FAILS="${MAX_FAILS:-3}"   # give up on a file after this many failed attempts
FAIL_TSV="$STATE_DIR/failed.tsv"   # ts<TAB>reason<TAB>path - so the dashboard can show WHY
PROBE_CACHE="$STATE_DIR/probe.cache"   # path<TAB>mtime<TAB>size<TAB>w<TAB>h<TAB>codec<TAB>pixfmt<TAB>prim<TAB>trc<TAB>fps<TAB>dur
# Durable per-file conversion stats (append-only, never regenerated): each DONE
# appends ts<TAB>mode<TAB>orig_bytes<TAB>new_bytes<TAB>delta_bytes<TAB>dest. The
# original size is knowable ONLY here (the source is deleted right after), and this
# survives plan.tsv rescans + log rotation — so all-time savings stay exact.
STATS_TSV="$STATE_DIR/converted.tsv"
touch "$DONE_LIST" "$FAIL_LIST" "$STATS_TSV" "$FAIL_TSV" "$PROBE_CACHE"
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# Clean shutdown: systemd stop / Ctrl-C must not leave stale telemetry (the dashboard
# would keep showing a phantom "now encoding") or a half-written scratch file.
# NOTE: files already staged in state/pending/ are deliberately LEFT for
# recover_pending() — they are verified replacements whose original is already gone.
RUBY_CURRENT_WORK=""
_ruby_cleanup(){
  local rc=$?
  [ -n "${RUBY_CURRENT_WORK:-}" ] && rm -f "$RUBY_CURRENT_WORK" 2>/dev/null
  rm -f "$STATE_DIR/current.json" 2>/dev/null
  log "interrupted (signal/exit rc=$rc) - telemetry cleared"
  exit $rc
}
trap _ruby_cleanup INT TERM HUP
human(){ numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1}B"; }
dur_of(){ ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null | cut -d. -f1; }

# Tell Plex to re-scan the folder of a just-replaced file so its DB updates the
# codec. Best-effort: never fails the encode. Maps the real on-disk dir to the
# path Plex knows (it stores files under the /mnt/movies|/mnt/shows symlink).
plex_notify(){  # $1=replaced file (real path)
  [ -n "$PLEX_TOKEN" ] || { log "plex_notify: no token, skipped"; return 0; }
  local rdir; rdir="$(dirname "$1")"
  local entry real plex sect pdir=""
  for entry in $PLEX_PATHMAP; do
    real="${entry%%:*}"; plex="${entry#*:}"; sect="${plex##*:}"; plex="${plex%:*}"
    case "$rdir" in "$real"/*) pdir="$plex${rdir#$real}"; break;; esac
  done
  [ -n "$pdir" ] || { log "plex_notify: no path map for $rdir, skipped"; return 0; }
  if curl -sf -G "$PLEX_URL/library/sections/$sect/refresh" \
        --data-urlencode "path=$pdir" --data-urlencode "X-Plex-Token=$PLEX_TOKEN" \
        -o /dev/null 2>/dev/null; then
    log "plex_notify: partial scan queued (section $sect) for $pdir"
  else
    log "plex_notify: refresh request failed for $pdir (non-fatal)"
  fi
}

# Ask Plex (via API key) what libraries exist. Emits one line per library Location:
#   <real-disk-path>\t<plex-path>\t<section-id>\t<type>
# Real path = the symlink target Plex's path resolves to (find needs real dirs).
plex_discover(){
  [ -n "$PLEX_TOKEN" ] || return 1
  curl -sf "$PLEX_URL/library/sections?X-Plex-Token=$PLEX_TOKEN" 2>/dev/null \
  | python3 -c '
import sys, os, xml.etree.ElementTree as ET
try: root = ET.fromstring(sys.stdin.read())
except Exception: sys.exit(1)
for d in root.findall("Directory"):
    key, typ = d.get("key"), d.get("type")
    for loc in d.findall("Location"):
        p = loc.get("path")
        if p: print("%s\t%s\t%s\t%s" % (os.path.realpath(p), p, key, typ))
' 2>/dev/null
}

# Resolution tier for a pixel width -> "4K" / "1080p" / "" (too small).
# Echoes "tier qual min_mbps" (qual = quality target for that tier).
tier_of(){  # $1=width
  local w="${1:-0}"
  if   [ "$w" -ge "$MIN_WIDTH_4K" ];   then echo "4K $Q_4K $MIN_MBPS_4K"
  elif [ "$w" -ge "$MIN_WIDTH_1080" ]; then echo "1080p $Q_1080 $MIN_MBPS_1080"
  elif [ "$w" -ge 1 ];                 then echo "720p $Q_720 999999"  # below 1080p: never a bitrate-shrink candidate (min_mbps huge), but eligible for compat re-encode at native res
  else echo ""; fi
}

# True if $1 lives under a TV-show library root (used to cap shows at 1080p).
is_show_path(){
  [ "${CAP_SHOWS_1080P:-1}" = 1 ] || return 1
  local p="$1" r
  for r in "${SHOW_ROOTS[@]}"; do case "$p" in "$r"/*) return 0;; esac; done
  return 1
}

# True when a path sits under an EXCLUDE_ROOTS entry (see config). Checked both at
# library discovery and per file, so an explicitly-passed file is covered too.
is_excluded(){
  # Compare CANONICAL paths. /mnt/homevideos is a symlink to the real library dir, so a
  # literal prefix test lets `ruby.sh /mnt/homevideos/clip.mkv` slip past an exclusion
  # that names the real path. Originals are deleted on replace, so this must not leak.
  local p="$1" e rp re
  rp="$(readlink -f -- "$p" 2>/dev/null || echo "$p")"
  for e in "${EXCLUDE_ROOTS[@]}"; do
    [ -n "$e" ] || continue
    re="$(readlink -f -- "$e" 2>/dev/null || echo "$e")"
    case "$p"  in "$e"|"$e"/*)   return 0;; esac
    case "$rp" in "$re"|"$re"/*) return 0;; esac
  done
  return 1
}

# Robustly read "<index> <lang>" lines for streams of a given type (a or s).
# lang is empty string when the stream has no language tag (common in raw m2ts).
_streams(){  # $1=file $2=a|s
  ffprobe -v error -select_streams "$2" \
    -show_entries stream=index:stream_tags=language -of compact=p=0:nk=0 "$1" 2>/dev/null \
  | while IFS= read -r line; do
      local idx lang
      idx="$(sed -n 's/.*\bindex=\([0-9]\+\).*/\1/p' <<<"$line")"
      lang="$(sed -n 's/.*language=\([A-Za-z]\+\).*/\1/p' <<<"$line")"
      [ -n "$idx" ] && printf '%s %s\n' "$idx" "$lang"
    done | awk '!seen[$1]++'   # dedupe: m2ts lists streams once per BDAV program
}

# Like _streams but for audio only, and it also carries the codec:
# "<index> <lang> <codec>". lang is "und" when the stream has no language tag.
_astreams(){  # $1=file
  ffprobe -v error -select_streams a \
    -show_entries stream=index,codec_name:stream_tags=language -of compact=p=0:nk=0 "$1" 2>/dev/null \
  | while IFS= read -r line; do
      local idx lang cod
      idx="$(sed -n 's/.*\bindex=\([0-9]\+\).*/\1/p' <<<"$line")"
      cod="$(sed -n 's/.*\bcodec_name=\([A-Za-z0-9_]\+\).*/\1/p' <<<"$line")"
      lang="$(sed -n 's/.*language=\([A-Za-z]\+\).*/\1/p' <<<"$line")"
      [ -n "$idx" ] && printf '%s %s %s\n' "$idx" "${lang:-und}" "${cod:-unknown}"
    done | awk '!seen[$1]++'   # dedupe: m2ts lists streams once per BDAV program
}

# audio to keep (echo space-separated SOURCE stream indices). English only:
#   1. if any track is tagged English (eng/en): keep the first English track, drop
#      every non-English track;
#   2. if NONE is tagged English: keep every UNTAGGED track (raw m2ts rarely tags
#      languages, so the English one is almost certainly among them) and drop tracks
#      tagged with another language. Before this rule, a "rus dub first + untagged
#      English" Blu-ray kept only the Russian dub (Miss Congeniality, Zulu, Waterworld,
#      Borat... lost their English in Sep/Oct 2026);
#   3. if there is no English and nothing untagged (a genuinely foreign-language
#      release), keep the primary track so the file still has sound;
#   4. then add the first already-direct-play-compatible track among the kept
#      language(s), if 1-3 didn't already catch one.
#
# Rule 4 matters more than it looks. A typical remux is "DTS-HD MA primary + AC3
# companion": has_good_audio() saw the AC3 and correctly decided no tracks needed
# ADDING, but the keep list was primary-only, so the AC3 was silently DROPPED. The
# output then had lossless-only audio and every TV had to transcode it — the exact
# opposite of what this tool exists to do. Keeping the compatible track costs ~640kbps
# and preserves direct play for free.
audio_keep_idxs(){
  local f="$1"; mapfile -t rows < <(_astreams "$f")
  [ ${#rows[@]} -eq 0 ] && return 1
  local r idx lang cod g out="" keep_lang
  for r in "${rows[@]}"; do read -r idx lang cod <<<"$r"
    case "$lang" in eng|en) out="$idx"; keep_lang=eng; break ;; esac
  done
  if [ -z "$out" ]; then
    for r in "${rows[@]}"; do read -r idx lang cod <<<"$r"
      [ "$lang" = und ] && out="${out:+$out }$idx"
    done
    [ -n "$out" ] && keep_lang=und
  fi
  if [ -z "$out" ]; then
    read -r idx keep_lang cod <<<"${rows[0]}"; out="$idx"
  fi
  # do the kept tracks already include a TV-friendly codec?
  local i
  for i in $out; do
    for r in "${rows[@]}"; do read -r idx lang cod <<<"$r"
      [ "$idx" = "$i" ] || continue
      for g in $GOOD_AUDIO; do [ "$cod" = "$g" ] && { printf '%s\n' "$out"; return 0; }; done
    done
  done
  # if not, adopt an existing compatible track in the language we're keeping
  # (if there is none, the caller adds AC3/AAC converted from the kept track).
  for r in "${rows[@]}"; do read -r idx lang cod <<<"$r"
    [ "$lang" = en ] && lang=eng
    [ "$lang" = "$keep_lang" ] || continue
    for g in $GOOD_AUDIO; do
      [ "$cod" = "$g" ] && { out="$out $idx"; break 2; }
    done
  done
  printf '%s\n' "$out"
}
# subs to keep (echo space-separated indices): all English-tagged; if NONE tagged
# eng (untagged m2ts), keep all subs.
sub_keep_idxs(){
  local f="$1"; mapfile -t rows < <(_streams "$f" s)
  [ ${#rows[@]} -eq 0 ] && return 0
  local r idx lang has_eng=0 out=""
  for r in "${rows[@]}"; do lang="${r#* }"; [ "$lang" = "eng" ] && has_eng=1; done
  for r in "${rows[@]}"; do idx="${r%% *}"; lang="${r#* }"
    if [ "$has_eng" = 1 ]; then [ "$lang" = "eng" ] && out="${out:+$out }$idx"
    else out="${out:+$out }$idx"; fi
  done
  printf '%s\n' "$out"
}

# first video stream codec name (tr strips any stray csv trailing comma/space)
vcodec_of(){ ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$1" 2>/dev/null | head -n1 | tr -d ', \t'; }

# ONE ffprobe for everything we need about a source: primary video stream plus the
# container duration. This replaced 8 separate invocations per file — on a ~5k-file
# library that is ~40k fewer process spawns (and file-header reads) per pass.
# Fields are exposed as PB_* globals; callers must call probe_src first.
PB_W=""; PB_H=""; PB_VCODEC=""; PB_PIXFMT=""; PB_PRIM=""; PB_TRC=""; PB_FPSR=""; PB_DUR=""
# Probe results keyed by path, validated against (mtime,size) so any edit or
# replacement invalidates the entry. A static library re-scans with no ffprobe at
# all: the 4,200+ files that classify as SKIP every pass were the bulk of the work.
declare -A PROBE_CACHE_MAP=()
_probe_cache_loaded=0
probe_cache_load(){
  [ "$_probe_cache_loaded" = 1 ] && return 0
  _probe_cache_loaded=1
  [ -r "$PROBE_CACHE" ] || return 0
  local line path rest
  while IFS= read -r line; do
    path="${line%%$'\t'*}"; rest="${line#*$'\t'}"
    [ -n "$path" ] && PROBE_CACHE_MAP["$path"]="$rest"
  done < "$PROBE_CACHE"
}

probe_src_uncached(){  # $1=file
  PB_W=""; PB_H=""; PB_VCODEC=""; PB_PIXFMT=""; PB_PRIM=""; PB_TRC=""; PB_FPSR=""; PB_DUR=""
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      width)           PB_W="$(printf '%s' "$v" | tr -dc '0-9')" ;;
      height)          PB_H="$(printf '%s' "$v" | tr -dc '0-9')" ;;
      codec_name)      PB_VCODEC="$(printf '%s' "$v" | tr -d ', \t')" ;;
      pix_fmt)         PB_PIXFMT="$v" ;;
      color_primaries) PB_PRIM="$v" ;;
      color_transfer)  PB_TRC="$v" ;;
      avg_frame_rate)  PB_FPSR="$v" ;;
      duration)        PB_DUR="${v%%.*}" ;;
    esac
  done < <(ffprobe -v error -select_streams v:0 \
             -show_entries stream=width,height,codec_name,pix_fmt,color_primaries,color_transfer,avg_frame_rate:format=duration \
             -of default=nw=1 "$1" 2>/dev/null)
  # ffprobe prints "N/A" for absent tags; normalise so callers can test emptiness.
  [ "$PB_PIXFMT" = "N/A" ] && PB_PIXFMT=""
  [ "$PB_PRIM"   = "N/A" ] && PB_PRIM=""
  [ "$PB_TRC"    = "N/A" ] && PB_TRC=""
  [ "$PB_FPSR"   = "N/A" ] && PB_FPSR=""
  [ "$PB_DUR"    = "N/A" ] && PB_DUR=""
}

probe_src(){  # $1=file  - cached wrapper around probe_src_uncached
  probe_cache_load
  local f="$1" st mt sz hit
  st=$(stat -c '%Y %s' -- "$f" 2>/dev/null) || { probe_src_uncached "$f"; return; }
  mt="${st%% *}"; sz="${st##* }"
  hit="${PROBE_CACHE_MAP["$f"]:-}"
  if [ -n "$hit" ]; then
    local c_mt c_sz
    IFS=$'\t' read -r c_mt c_sz PB_W PB_H PB_VCODEC PB_PIXFMT PB_PRIM PB_TRC PB_FPSR PB_DUR <<<"$hit"
    if [ "$c_mt" = "$mt" ] && [ "$c_sz" = "$sz" ]; then
      return 0                      # cache hit: no ffprobe at all
    fi
  fi
  probe_src_uncached "$f"
  # Append-only writes are cheap and crash-safe; compact when the file grows past
  # ~2x the map size so re-probed entries do not accumulate forever.
  if [ $(( ${#PROBE_CACHE_MAP[@]} + 1 )) -gt 200 ]; then
    local _rows; _rows=$(grep -c "" "$PROBE_CACHE" 2>/dev/null | head -n1); _rows="${_rows:-0}"
    if [ "$_rows" -gt $(( ${#PROBE_CACHE_MAP[@]} * 2 )) ]; then
      local _tmpc="$PROBE_CACHE.compact.$$"
      : > "$_tmpc"
      local _k
      for _k in "${!PROBE_CACHE_MAP[@]}"; do
        printf '%s\t%s\n' "$_k" "${PROBE_CACHE_MAP["$_k"]}" >> "$_tmpc"
      done
      mv -f "$_tmpc" "$PROBE_CACHE" && log "probe cache compacted: $_rows -> ${#PROBE_CACHE_MAP[@]} rows"
    fi
  fi
  local row
  printf -v row '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$mt" "$sz" "$PB_W" "$PB_H" "$PB_VCODEC" "$PB_PIXFMT" "$PB_PRIM" "$PB_TRC" "$PB_FPSR" "$PB_DUR"
  PROBE_CACHE_MAP["$f"]="$row"
  printf '%s\t%s\n' "$f" "$row" >> "$PROBE_CACHE"
}
# Do the audio tracks we are actually KEEPING include a TV-friendly codec?
# Deliberately scoped to the kept set rather than the whole file: a source can own a
# compatible track that the keep rules discard, and in that case the output still
# needs one added. (Asking the file-wide question here is what let files come out
# lossless-only — see audio_keep_idxs.)
kept_has_good_audio(){  # $1=file  $2=space-separated kept stream indices
  local f="$1" idxs="$2" i c g
  for i in $idxs; do
    c=$(ffprobe -v error -select_streams "$i" -show_entries stream=codec_name \
          -of default=nw=1:nk=1 "$f" 2>/dev/null | head -n1 | tr -d ', \t')
    for g in $GOOD_AUDIO; do [ "$c" = "$g" ] && return 0; done
  done
  return 1
}

# emit a plan line (decision<TAB>detail<TAB>bytes<TAB>path) when PLAN_OUT is set
# Record a failure WITH a reason. failed.list stays (resume/compat); failed.tsv adds
# the reason so the dashboard can group failures instead of printing "see log".
record_fail(){  # $1=src  $2=reason
  echo "$1" >> "$FAIL_LIST"
  printf '%s\t%s\t%s\n' "$(date +%s)" "${2//$'\t'/ }" "$1" >> "$FAIL_TSV"
}

plan(){ [ -n "${PLAN_OUT:-}" ] && printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$PLAN_OUT"; }

process(){
  local src="$1"
  is_excluded "$src" && { log "SKIP(excluded): $(basename "$src")"; return 0; }
  local size; size=$(stat -c%s "$src" 2>/dev/null || echo 0)
  grep -qxF "$src" "$DONE_LIST" && { plan DONE done "$size" "$src"; log "SKIP(done): $(basename "$src")"; return 0; }
  # Retry cap: a file that has failed MAX_FAILS times will keep failing (bad source,
  # unsupported format, ...). Re-encoding it every pass burns GPU time for nothing.
  # Clear its lines from state/failed.list to force a retry after a config/ffmpeg change.
  # NB grep -c PRINTS a count and EXITS 1 when the count is zero, so a `|| echo 0`
  # fallback appends a second line and yields "0\n0". Take the first line instead.
  local _nfail; _nfail=$(grep -cxF -- "$src" "$FAIL_LIST" 2>/dev/null | head -n1); _nfail="${_nfail:-0}"
  if [ "${_nfail:-0}" -ge "$MAX_FAILS" ]; then
    plan SKIP "failed ${_nfail}x (capped)" "$size" "$src"
    log "SKIP(failed ${_nfail}x >= MAX_FAILS=$MAX_FAILS): $(basename "$src")"
    return 0
  fi
  local base dir stem; base="$(basename "$src")"
  dir="$(dirname "$src")"; stem="${base%.*}"
  local work="$SCRATCH/${stem}.hevc.mkv" dest="$dir/${stem}.mkv"
  RUBY_CURRENT_WORK="$work"

  # --- classify: probe and decide WHY (if at all) this file should be processed ---
  local w hgt od
  probe_src "$src"                 # single ffprobe: w/h/codec/pix_fmt/colour/fps/duration
  w="$PB_W"; hgt="$PB_H"; od="$PB_DUR"
  [ -z "$w" ] && { plan SKIP "no video" "$size" "$src"; log "SKIP(no video): $base"; return 0; }
  local tinfo tier qval min_mbps; tinfo="$(tier_of "${w:-0}")"
  [ -z "$tinfo" ] && { plan SKIP "no resolution (${w}px)" "$size" "$src"; log "SKIP(no res w=$w): $base"; return 0; }
  read -r tier qval min_mbps <<<"$tinfo"
  local vcod; vcod="$PB_VCODEC"

  # TV cap: shows are never kept at 4K -> downscale to 1080p (movies unaffected).
  # A 4K episode is retiered to 1080p (Q_1080), and a scale target height is computed
  # keeping aspect ratio (even number). This forces a re-encode regardless of bitrate.
  local cap1080=0 tw=0 th=0
  if [ "$tier" = "4K" ] && is_show_path "$src"; then
    cap1080=1; tier="1080p"; qval="$Q_1080"; min_mbps="$MIN_MBPS_1080"
    tw=1920
    th=$(( (w>0 && hgt>0) ? (hgt*tw + w/2)/w : 1080 )); th=$(( (th/2)*2 ))
  fi

  # Decide which audio survives BEFORE deciding why we're touching the file: whether
  # compatible audio must be ADDED depends on what we're keeping, not on what the
  # source merely contains. (These two questions used to disagree — the source could
  # own an AC3 track that satisfied the check and was then dropped by the keep rules.)
  local keepidx; keepidx="$(audio_keep_idxs "$src")" || { plan SKIP "no audio" "$size" "$src"; log "FAIL(no audio): $base"; record_fail "$src" "no audio stream"; return 1; }
  local keep; read -ra keep <<<"$keepidx"

  # Reasons to touch a file:
  #   shrink   = large high-bitrate remux (original behaviour)       -> HEVC re-encode, smaller
  #   vcodec   = client-incompatible video codec (vc1/mpeg2/av1/...) -> HEVC re-encode, resolution kept
  #   audio    = no TV-friendly audio codec among the KEPT tracks    -> add AC3/AAC tracks
  #   cap1080  = 4K show being downscaled to 1080p                   -> HEVC re-encode at 1080p
  local reason_shrink=0 reason_vcodec=0 reason_audio=0 mbps=0 b
  if [ "$size" -ge $((MIN_SIZE_GB*1000000000)) ] && [ "${od:-0}" -gt 0 ]; then
    mbps=$(( size * 8 / od / 1000000 ))
    [ "$mbps" -ge "$min_mbps" ] && reason_shrink=1
  fi
  for b in $BAD_VIDEO; do [ "$vcod" = "$b" ] && { reason_vcodec=1; break; }; done
  kept_has_good_audio "$src" "$keepidx" || reason_audio=1

  local mode why=""
  [ "$cap1080" = 1 ]      && why="downscale4K->1080p"
  [ "$reason_shrink" = 1 ] && why="${why:+$why,}shrink:${mbps}Mbps"
  [ "$reason_vcodec" = 1 ] && why="${why:+$why,}codec:$vcod"
  [ "$reason_audio"  = 1 ] && why="${why:+$why,}audio"
  if [ "$cap1080" = 1 ] || [ "$reason_shrink" = 1 ] || [ "$reason_vcodec" = 1 ]; then mode=encode
  elif [ "$reason_audio" = 1 ]; then mode=remux
  else
    plan SKIP "ok (${tier} ${vcod} ${mbps}Mbps audio-ok)" "$size" "$src"
    log "SKIP(ok ${tier} ${vcod} ${mbps}Mbps): $base"; return 0
  fi

  # --- audio: keep list settled above; add compatible tracks if none survived ---
  local prim="${keep[0]}" primlang primch
  primlang=$(ffprobe -v error -select_streams a:0 -show_entries stream_tags=language -of default=nw=1:nk=1 "$src" 2>/dev/null | head -n1 | tr -dc 'A-Za-z'); [ -n "$primlang" ] || primlang=eng
  primch=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=nw=1:nk=1 "$src" 2>/dev/null | head -n1 | tr -dc '0-9'); [ "${primch:-0}" -ge 1 ] 2>/dev/null || primch=2
  local amap=() acodec=(-c:a copy) an=${#keep[@]} i
  for i in "${keep[@]}"; do amap+=(-map "0:$i"); done
  if [ "$reason_audio" = 1 ]; then
    if [ "${ADD_AC3:-1}" = 1 ]; then
      local ac3ch=$primch ac3br=256k; [ "$ac3ch" -gt 6 ] && ac3ch=6; [ "$ac3ch" -ge 6 ] && ac3br=640k
      amap+=(-map "0:$prim")
      acodec+=("-c:a:$an" ac3 "-b:a:$an" "$ac3br" "-ac:a:$an" "$ac3ch" "-metadata:s:a:$an" "language=$primlang" "-metadata:s:a:$an" "title=Dolby Digital 5.1")
      an=$((an+1)); why="${why}+AC3"
    fi
    if [ "${ADD_AAC:-1}" = 1 ]; then
      amap+=(-map "0:$prim")
      acodec+=("-c:a:$an" aac "-b:a:$an" 192k "-ac:a:$an" 2 "-metadata:s:a:$an" "language=$primlang" "-metadata:s:a:$an" "title=AAC Stereo")
      an=$((an+1)); why="${why}+AAC"
    fi
  fi
  local subidx; subidx="$(sub_keep_idxs "$src")"
  local smap=(); for i in $subidx; do smap+=(-map "0:$i"); done

  # --- encoder plan (encode mode only): match profile/rc/format/colour to the SOURCE ---
  # 10-bit (HDR or 10-bit SDR): Main10 + ICQ (only mode this iGPU supports at 10-bit).
  # 8-bit  (typical SDR 1080p): Main + CQP + explicit scale_vaapi=nv12 (ICQ unsupported,
  #                             and the H.264->HEVC surface needs an explicit format).
  # Colour: keep bt2020/PQ(HLG) for HDR; Rec.709 otherwise. Never mislabel SDR as HDR.
  local pixfmt prim_c trc is10=0 ishdr=0 prof qlabel vf=() rc=() color=()
  if [ "$mode" = encode ]; then
    # NOTE: default=nk=1 (not csv) — ffprobe's csv writer appends a stray trailing
    # comma on some files, which silently broke HDR/10-bit detection (encoding HDR as
    # 8-bit SDR). default:nk=1 returns the bare value with no separator.
    pixfmt="$PB_PIXFMT"; prim_c="$PB_PRIM"; trc="$PB_TRC"
    { [ "$trc" = "smpte2084" ] || [ "$trc" = "arib-std-b67" ] || [ "$prim_c" = "bt2020" ]; } && ishdr=1
    case "$pixfmt" in *10le|*10be|p010*) is10=1 ;; esac
    [ "$ishdr" = 1 ] && is10=1
    # Downscale filter for the TV 4K->1080p cap (empty otherwise). scale_vaapi runs
    # on the GPU surface; the 8-bit path also needs format=nv12 (as before).
    local scale=""; [ "$cap1080" = 1 ] && scale="scale_vaapi=w=${tw}:h=${th}"
    if [ "$is10" = 1 ]; then
      prof=main10; rc=(-rc_mode ICQ -global_quality "$qval"); qlabel="ICQ$qval"
      # The filter chain MUST declare the surface format, exactly like the 8-bit path.
      # Without it ffmpeg inserts auto_scale between the VAAPI decode surface and
      # hevc_vaapi, which cannot convert hw formats:
      #   "Impossible to convert between the formats supported by 'Parsed_null_0'
      #    and 'auto_scale_0'" -> -38 -> "Could not open encoder" -> -22.
      # That accounted for 112 of 140 historical failures (all 10-bit/HDR sources).
      if [ -n "$scale" ]; then vf=(-vf "${scale}:format=p010"); else vf=(-vf scale_vaapi=format=p010); fi
    else
      prof=main; rc=(-rc_mode CQP -qp "$qval"); qlabel="QP$qval"
      if [ -n "$scale" ]; then vf=(-vf "${scale}:format=nv12"); else vf=(-vf scale_vaapi=format=nv12); fi
    fi
    [ "$cap1080" = 1 ] && qlabel="${qlabel}↓1080p"
    if [ "$ishdr" = 1 ]; then
      color=(-color_primaries bt2020 -color_trc "${trc:-smpte2084}" -colorspace bt2020nc)
    elif [ "$is10" = 1 ]; then
      color=(-color_primaries bt709 -color_trc bt709 -colorspace bt709)
    fi  # 8-bit SDR: leave colour unspecified (this iGPU's Main encoder returns -22 on explicit flags)
  else
    qlabel="remux"   # video copied untouched; only audio tracks are (re)built
  fi

  plan CONVERT "${mode}:${why} (${tier})" "$size" "$src"
  log "START($mode): $base [$tier $qlabel ${prof:-copy}] ($(human "$size")) why[$why] keepA[${keep[*]}] keepS[$subidx]"
  { [ "$DRY_RUN" = "1" ] || [ -n "${PLAN_OUT:-}" ]; } && { log "DRY_RUN only"; return 0; }

  # publish current-conversion telemetry for the dashboard.
  # Include the source frame rate: some encodes report out_time=N/A via -progress,
  # so the dashboard needs frame/total_frames as a fallback for percent complete.
  local _fpsr _fps _tframes
  _fpsr="$PB_FPSR"
  _fps="$(awk -F/ 'NF==2 && $2>0 {printf "%.6f", $1/$2; exit} NF==1 {print $1; exit}' <<<"${_fpsr:-0}")"
  _tframes="$(awk -v d="${od:-0}" -v f="${_fps:-0}" 'BEGIN{printf "%d", (d>0&&f>0)? d*f : 0}')"
  printf '{"src":"%s","base":"%s","size":%s,"duration":%s,"width":%s,"tier":"%s","quality":"%s","fps_src":%s,"total_frames":%s,"start":%s}\n' \
    "${src//\"/}" "${base//\"/}" "$size" "${od:-0}" "${w:-0}" "$tier" "$qlabel" "${_fps:-0}" "${_tframes:-0}" "$(date +%s)" > "$STATE_DIR/current.json"
  : > "$STATE_DIR/current.progress"

  rm -f "$work"
  if [ "$mode" = encode ]; then
    if ! nice -n 10 ffmpeg -nostdin -hide_banner -loglevel error -y -progress "$STATE_DIR/current.progress" \
          -init_hw_device vaapi=va:"$RENDER" -hwaccel vaapi -hwaccel_output_format vaapi \
          -i "$src" -map 0:v:0 "${amap[@]}" "${smap[@]}" -map_chapters 0 "${vf[@]}" \
          -c:v hevc_vaapi "${rc[@]}" -profile:v "$prof" "${color[@]}" \
          "${acodec[@]}" -c:s copy "$work" 2>>"$LOG"; then
      log "FAIL(ffmpeg): $base"; record_fail "$src" "ffmpeg:$mode"; rm -f "$work" "$STATE_DIR/current.json"; return 1
    fi
  else   # remux: video copied bit-for-bit, only the audio tracks are rebuilt (no quality loss)
    if ! nice -n 10 ffmpeg -nostdin -hide_banner -loglevel error -y -progress "$STATE_DIR/current.progress" \
          -i "$src" -map 0:v:0 "${amap[@]}" "${smap[@]}" -map_chapters 0 \
          -c:v copy "${acodec[@]}" -c:s copy "$work" 2>>"$LOG"; then
      log "FAIL(ffmpeg): $base"; record_fail "$src" "verify:$mode newsize=$nsize vcodec=$nvc ddiff=${ddiff}s audio=$nac/$an"; rm -f "$work" "$STATE_DIR/current.json"; return 1
    fi
  fi

  # --- verify (mode-aware) ---
  local nsize nd nvc nac ddiff vfail=0
  nsize=$(stat -c%s "$work" 2>/dev/null || echo 0); nd=$(dur_of "$work")
  nvc=$(vcodec_of "$work")
  nac=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$work" 2>/dev/null | wc -l)
  ddiff=$(( ${od:-0} - ${nd:-0} )); ddiff=${ddiff#-}
  [ "$nsize" -lt 1000000 ] && vfail=1            # produced something real
  [ "$ddiff" -gt 3 ] && vfail=1                  # full-length (no truncation)
  [ "$nac" -lt "$an" ] && vfail=1                # all kept + added audio tracks present
  if [ "$mode" = encode ]; then
    [ "$nvc" != "hevc" ] && vfail=1
    [ "$reason_shrink" = 1 ] && [ "$nsize" -ge "$size" ] && vfail=1   # shrink jobs must shrink; pure-compat jobs may grow
    if [ "$cap1080" = 1 ]; then
      local nw; nw=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$work" 2>/dev/null | head -n1 | tr -dc '0-9')
      [ "${nw:-0}" -gt 1928 ] && vfail=1                              # downscale must have applied (~1920 wide)
    fi
  else
    [ -z "$nvc" ] && vfail=1                      # remux: video stream survived
  fi
  if [ "$vfail" = 1 ]; then
    log "FAIL(verify): $base mode=$mode newsize=$(human "$nsize") vcodec=$nvc dur_diff=${ddiff}s audio=$nac/want$an"
    echo "$src">>"$FAIL_LIST"; rm -f "$work" "$STATE_DIR/current.json"; return 1
  fi

  # --- replace: write the verified work file into place ---
  # Size-aware free-space check: a copy-alongside needs room for the new file (which
  # lands beside the original until the atomic rename) plus a safety margin.
  local freeg needg; freeg=$(df -BG --output=avail "$dir" | tail -1 | tr -dc '0-9')
  needg=$(( nsize/1000000000 + 10 )); [ "$needg" -lt "$MIN_FREE_GB" ] && needg=$MIN_FREE_GB
  if [ "${freeg:-0}" -ge "$needg" ]; then
    # NORMAL: copy alongside, atomic rename, then drop the old original. Crash-safe:
    # the original survives until the verified copy is renamed into place.
    local tmpdest="$dir/.${stem}.compressing.mkv"
    if ! cp -f "$work" "$tmpdest" || [ "$(stat -c%s "$tmpdest")" != "$nsize" ]; then
      log "FAIL(copy): $base"; record_fail "$src" "copy: could not write beside original"; rm -f "$work" "$tmpdest" "$STATE_DIR/current.json"; return 1
    fi
    mv -f "$tmpdest" "$dest"
    [ "$src" != "$dest" ] && rm -f "$src"
    rm -f "$work"
  else
    # TIGHT-SPACE: the drive is too full for a copy-alongside. The work file is already
    # a VERIFIED valid replacement, so: move it out of the wiped scratch into durable
    # state/pending/ (an instant same-filesystem NVMe rename) alongside a .meta record,
    # delete the now-redundant original to free room, then copy the (smaller) output into
    # place. A crash mid-copy is finished by recover_pending() on the next start — at
    # every instant either the original OR a verified copy exists, so nothing is lost.
    # A GROW job (audio-add remux can output LARGER than the source) may not fit even
    # after freeing the original on a totally-full drive. Guard FIRST so we never delete
    # an original we can't replace: if freeing it still won't make room, defer this file
    # (keep the original untouched) — shrink jobs will free space and a later pass retries.
    local freeb; freeb=$(df -B1 --output=avail "$dir" 2>/dev/null | tail -1 | tr -dc '0-9')
    if [ "$(( ${freeb:-0} + size ))" -lt "$(( nsize + 536870912 ))" ]; then
      log "DEFER(tight: post-free $(human $(( ${freeb:-0} + size ))) < needed $(human $(( nsize + 536870912 ))), original kept): $base"
      rm -f "$work" "$STATE_DIR/current.json"; return 1
    fi
    local PENDING="$STATE_DIR/pending"; mkdir -p "$PENDING"
    local pend="$PENDING/${stem}.mkv" pmeta="$PENDING/${stem}.meta"
    if ! mv -f "$work" "$pend"; then
      log "FAIL(stage): $base"; record_fail "$src" "stage: could not move work file to pending/"; rm -f "$work" "$STATE_DIR/current.json"; return 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$src" "$dest" "$size" "$nsize" "$mode" > "$pmeta"
    log "TIGHT-SPACE(${freeg}G free < ${needg}G): staged verified copy, freeing original: $base"
    rm -f "$src"
    local ttmp="$dir/.${stem}.recovering.mkv"
    if ! cp -f "$pend" "$ttmp" || [ "$(stat -c%s "$ttmp")" != "$nsize" ]; then
      rm -f "$ttmp"       # never leave a partial at the library path; verified copy stays in pending/
      log "FAIL(tight-copy): $base — verified copy kept in pending/, recovered next cycle"
      rm -f "$STATE_DIR/current.json"; return 1
    fi
    mv -f "$ttmp" "$dest"                            # atomic swap into place
    [ "$src" != "$dest" ] && rm -f "$src"
    rm -f "$pend" "$pmeta"
  fi
  rm -f "$STATE_DIR/current.json"
  RUBY_CURRENT_WORK=""
  echo "$dest">>"$DONE_LIST"
  local delta=$((size-nsize))
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$mode" "$size" "$nsize" "$delta" "$dest" >>"$STATS_TSV"
  log "DONE($mode): $base $(human "$size") -> $(human "$nsize") (delta $(human "$delta"))"
  plex_notify "$dest"
}

############################## MAIN ###########################################
# Finish any TIGHT-SPACE replace that was interrupted by a crash/restart. Each
# state/pending/<stem>.meta (src<TAB>dest<TAB>orig<TAB>new<TAB>mode) has a verified
# <stem>.mkv beside it; if its dest isn't already in place, copy it in and record it.
recover_pending(){
  local PENDING="$STATE_DIR/pending" pmeta stem pend src dest sz nsz mode
  [ -d "$PENDING" ] || return 0
  shopt -s nullglob
  for pmeta in "$PENDING"/*.meta; do
    stem="$(basename "$pmeta" .meta)"; pend="$PENDING/${stem}.mkv"
    IFS=$'\t' read -r src dest sz nsz mode < "$pmeta"
    [ -f "$pend" ] || { rm -f "$pmeta"; continue; }
    if [ -f "$dest" ] && [ "$(stat -c%s "$dest" 2>/dev/null)" = "$nsz" ]; then
      grep -qxF "$dest" "$DONE_LIST" || echo "$dest">>"$DONE_LIST"
      rm -f "$pend" "$pmeta"; continue
    fi
    local fb; fb=$(df -B1 --output=avail "$(dirname "$dest")" 2>/dev/null | tail -1 | tr -dc '0-9')
    [ "${fb:-0}" -lt "$(( ${nsz:-0} + 536870912 ))" ] && continue   # not enough room yet; retry a later cycle
    log "Ruby: recovering interrupted replace -> $(basename "$dest")"
    local rtmp; rtmp="$(dirname "$dest")/.$(basename "$dest" .mkv).recovering.mkv"
    if cp -f "$pend" "$rtmp" && [ "$(stat -c%s "$rtmp" 2>/dev/null)" = "$nsz" ]; then
      mv -f "$rtmp" "$dest"                          # atomic — library path never holds a partial
      [ -n "$src" ] && [ "$src" != "$dest" ] && rm -f "$src"
      echo "$dest">>"$DONE_LIST"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${mode:-encode}" "$sz" "$nsz" "$((sz-nsz))" "$dest" >>"$STATS_TSV"
      rm -f "$pend" "$pmeta"; plex_notify "$dest"
    else
      rm -f "$rtmp"                                  # drop any partial; keep verified copy in pending
      log "Ruby: recovery copy failed for $(basename "$dest") — will retry next cycle"
    fi
  done
  shopt -u nullglob
}

# Discover libraries from Plex (section ids for re-indexing + which dirs to scan).
# Falls back to the configured ROOTS/PLEX_PATHMAP if Plex is unreachable.
discover_libraries(){
  local libs line rp pp key typ t
  mapfile -t libs < <(plex_discover)
  [ ${#libs[@]} -gt 0 ] || { log "Ruby: Plex discovery unavailable — using configured ROOTS/PATHMAP"; return 0; }
  # Collect roots split by type so we can order SHOWS-FIRST: TV libraries are
  # optimised before Movies (any other enabled type follows). The main loop then
  # scans each root in this order, so shows are fully processed before movies.
  local show_roots=() other_roots=() pathmap=""
  for line in "${libs[@]}"; do
    IFS=$'\t' read -r rp pp key typ <<<"$line"
    [ -n "$rp" ] || continue
    pathmap="${pathmap:+$pathmap }${rp}:${pp}:${key}"
    if is_excluded "$rp"; then log "Ruby: library '${pp}' (section $key, $typ) -> EXCLUDED by EXCLUDE_ROOTS ($rp)"; continue; fi
    for t in $PLEX_LIB_TYPES; do
      if [ "$typ" = "$t" ] && [ -d "$rp" ]; then
        if [ "$typ" = show ]; then show_roots+=("$rp"); else other_roots+=("$rp"); fi
        log "Ruby: library '${pp}' (section $key, $typ) -> scan $rp"
      fi
    done
  done
  PLEX_PATHMAP="$pathmap"
  [ ${#show_roots[@]} -gt 0 ] && SHOW_ROOTS=("${show_roots[@]}")
  local roots=("${show_roots[@]}" "${other_roots[@]}")
  [ ${#roots[@]} -gt 0 ] && ROOTS=("${roots[@]}")
}

discover_libraries
recover_pending   # finish any tight-space replace interrupted by a prior crash/restart
if [ $# -ge 1 ]; then for f in "$@"; do process "$f"; done; exit 0; fi
log "=== Ruby - Plex Optimiser (by Andrew Marsh) start | shrink: 4K Q=$Q_4K >=${MIN_MBPS_4K}Mbps / 1080p Q=$Q_1080 >=${MIN_MBPS_1080}Mbps >=${MIN_SIZE_GB}G | compat: codec[$BAD_VIDEO] + audio[AC3=$ADD_AC3 AAC=$ADD_AAC] | scan >=${SCAN_MIN_MB}MB over [${ROOTS[*]}] ==="
# Scan each root SEPARATELY, in ROOTS order (shows-first, set by discover_libraries),
# sorting only WITHIN each root. A single find+global-sort would interleave the
# libraries alphabetically by path and defeat the shows-before-movies ordering.
for root in "${ROOTS[@]}"; do
  [ -d "$root" ] || continue
  log "Ruby: scanning library root $root"
  while IFS= read -r -d '' f; do
    recover_pending   # place any deferred/interrupted replaces now that shrink jobs may have freed space
    process "$f"
  done < <(
    find "$root" -type f \( -iname '*.mkv' -o -iname '*.m2ts' -o -iname '*.mp4' -o -iname '*.ts' \) \
         -size +"${SCAN_MIN_MB}"M -print0 2>/dev/null | sort -z)
done
log "=== Ruby: batch complete. Done=$(wc -l <"$DONE_LIST") Failed=$(wc -l <"$FAIL_LIST") ==="
