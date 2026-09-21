#!/usr/bin/env bash
# Regression test: the pool must never exceed its limit, even when the governor
# returns garbage (this caused a fork bomb: load 227).
set -uo pipefail
AUDIO_HARD_MAX=4
sane_jobs(){
  local v="${1:-}"
  case "$v" in (''|*[!0-9]*) v=1 ;; esac
  [ "$v" -lt 1 ] && v=1
  [ "$v" -gt "$AUDIO_HARD_MAX" ] && v="$AUDIO_HARD_MAX"
  printf '%s' "$v"
}
pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   sane_jobs(%-34s) -> %s\n' "$1" "$2"
      else fail=$((fail+1)); printf '  FAIL sane_jobs(%-34s) -> got %s want %s\n' "$1" "$2" "$3"; fi; }
ck "'2'"                     "$(sane_jobs '2')"                       2
ck "'' (empty)"              "$(sane_jobs '')"                        1
ck "'0'"                     "$(sane_jobs '0')"                       1
ck "'99'"                    "$(sane_jobs '99')"                      4
ck "'-3'"                    "$(sane_jobs '-3')"                      1
ck "log-leak text"           "$(sane_jobs '[ts] audio governor: 2')"  1
ck "multiline '0\n0'"        "$(sane_jobs "$(printf '0\n0')")"        1
ck "'2 extra'"               "$(sane_jobs '2 extra')"                 1

# real pool behaviour with a hostile governor
echo "  --- live pool test: governor returns garbage every time ---"
bad_gov(){ printf '[ts] audio governor: 3\n3'; }
JOBS=$(sane_jobs "$(bad_gov)")
peak=0
for i in $(seq 1 12); do
  ( sleep 0.4 ) &
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || break; JOBS=$(sane_jobs "$(bad_gov)"); done
  while [ "$(jobs -rp | wc -l)" -ge "$AUDIO_HARD_MAX" ]; do wait -n 2>/dev/null || break; done
  c=$(jobs -rp | wc -l); [ "$c" -gt "$peak" ] && peak=$c
done
wait
if [ "$peak" -le "$AUDIO_HARD_MAX" ]; then pass=$((pass+1)); echo "  ok   peak concurrency $peak <= hard max $AUDIO_HARD_MAX"
else fail=$((fail+1)); echo "  FAIL peak concurrency $peak > hard max $AUDIO_HARD_MAX"; fi
echo; echo "  $pass passed, $fail failed"
[ "$fail" = 0 ]
