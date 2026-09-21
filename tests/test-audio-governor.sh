#!/usr/bin/env bash
set -uo pipefail
# Unit test for ruby-music.sh audio_jobs_now(). Stubs the CPU/Plex probes so the
# step logic is tested deterministically. Run: tests/test-audio-governor.sh
STATE=/tmp/gt; mkdir -p "$STATE"
MUSIC_JOBS=4; PLEX_URL=http://127.0.0.1:32400; PLEX_TOKEN=""
log(){ :; }
AUDIO_JOBS_CUR=1; AUDIO_LAST_EVAL=0
AUDIO_EVAL_SEC=15; AUDIO_IDLE_UP=25; AUDIO_IDLE_DOWN=10; AUDIO_IOWAIT_CEIL=55
# load ONLY the decision function; stub the two probes it calls
eval "$(sed -n '/^audio_jobs_now(){/,/^}$/p' /home/naboo/ruby/ruby-music.sh)"
cpu_sample(){ echo "$FAKE_IDLE $FAKE_IOW"; }
plex_video_transcodes(){ echo "$FAKE_TX"; }

pass=0; fail=0
step(){ AUDIO_LAST_EVAL=0; audio_jobs_now >/dev/null 2>&1; }
check(){ if [ "$AUDIO_JOBS_CUR" = "$2" ]; then pass=$((pass+1)); printf '  ok   %-38s -> %s\n' "$1" "$AUDIO_JOBS_CUR"
         else fail=$((fail+1)); printf '  FAIL %-38s -> got %s want %s\n' "$1" "$AUDIO_JOBS_CUR" "$2"; fi; }

AUDIO_JOBS_CUR=1; FAKE_TX=0; FAKE_IOW=5; FAKE_IDLE=80
step; check "idle box: ramp 1->2" 2
step; check "idle box: ramp 2->3" 3
step; check "idle box: ramp 3->4" 4
step; check "capped at MUSIC_JOBS=4" 4

FAKE_IDLE=5
step; check "cpu saturated: 4->3" 3
step; check "cpu saturated: 3->2" 2
step; check "cpu saturated: 2->1" 1
step; check "floor at 1" 1

FAKE_IDLE=80; FAKE_IOW=70; AUDIO_JOBS_CUR=3
step; check "disk-bound iowait 70: 3->2" 2
step; check "disk-bound: 2->1" 1

FAKE_IOW=5; FAKE_IDLE=80; AUDIO_JOBS_CUR=3; FAKE_TX=1
step; check "plex transcode: immediate 1" 1

FAKE_TX=0; FAKE_IDLE=18; AUDIO_JOBS_CUR=2
step; check "middling idle 18: hold at 2" 2
AUDIO_JOBS_CUR=3
step; check "middling idle 18: hold at 3" 3

FAKE_IDLE=80; FAKE_IOW=5; AUDIO_JOBS_CUR=2; AUDIO_LAST_EVAL=$(date +%s)
audio_jobs_now >/dev/null 2>&1
check "inside eval window: no change" 2

# --- regressions -----------------------------------------------------------
# audio_jobs_now's value is read with $(...), so ANY stdout written inside it
# (e.g. a log line) would be captured as part of the job count.
FAKE_TX=0; FAKE_IDLE=80; FAKE_IOW=5; AUDIO_JOBS_CUR=1; AUDIO_LAST_EVAL=0
out=$(audio_jobs_now 2>/dev/null)
if [[ "$out" =~ ^[0-9]+$ ]]; then pass=$((pass+1)); printf '  ok   %-38s -> %q\n' "returns a bare integer" "$out"
else fail=$((fail+1)); printf '  FAIL %-38s -> %q\n' "returns a bare integer" "$out"; fi

# grep -c PRINTS 0 and EXITS 1 when nothing matches, so `|| echo 0` yields "0\n0".
probe_out=$(printf '' | grep -c 'nothing' 2>/dev/null | head -n1)
if [ "${probe_out:-0}" = "0" ]; then pass=$((pass+1)); printf '  ok   %-38s -> %q\n' "transcode count is a single value" "${probe_out}"
else fail=$((fail+1)); printf '  FAIL %-38s -> %q\n' "transcode count is a single value" "${probe_out}"; fi

# The governor must be called DIRECTLY. Via $(...) it runs in a subshell and its
# state is discarded, so it can step 1->2 and never reach 3 or 4.
FAKE_TX=0; FAKE_IDLE=80; FAKE_IOW=5; AUDIO_JOBS_CUR=1; AUDIO_LAST_EVAL=0
_=$(audio_jobs_now 2>/dev/null)
if [ "$AUDIO_JOBS_CUR" = "1" ]; then pass=$((pass+1)); printf '  ok   %-38s -> state lost as expected\n' "via \$(...) : subshell"
else fail=$((fail+1)); printf '  FAIL %-38s -> %s\n' "via \$(...) : subshell" "$AUDIO_JOBS_CUR"; fi
AUDIO_LAST_EVAL=0; audio_jobs_now >/dev/null 2>&1
if [ "$AUDIO_JOBS_CUR" = "2" ]; then pass=$((pass+1)); printf '  ok   %-38s -> %s\n' "direct call: state persists" "$AUDIO_JOBS_CUR"
else fail=$((fail+1)); printf '  FAIL %-38s -> got %s want 2\n' "direct call: state persists" "$AUDIO_JOBS_CUR"; fi
AUDIO_LAST_EVAL=0; audio_jobs_now >/dev/null 2>&1
AUDIO_LAST_EVAL=0; audio_jobs_now >/dev/null 2>&1
if [ "$AUDIO_JOBS_CUR" = "4" ]; then pass=$((pass+1)); printf '  ok   %-38s -> %s\n' "climbs past 2 to the ceiling" "$AUDIO_JOBS_CUR"
else fail=$((fail+1)); printf '  FAIL %-38s -> got %s want 4\n' "climbs past 2 to the ceiling" "$AUDIO_JOBS_CUR"; fi

echo; echo "  $pass passed, $fail failed"
rm -rf "$STATE"
[ "$fail" = 0 ]
