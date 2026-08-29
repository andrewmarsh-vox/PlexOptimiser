#!/usr/bin/env bash
# Quick status/control for the media compression batch.
cd /home/naboo/ruby || exit 1
echo "=== RUNNING? ==="
if pgrep -f ruby.sh >/dev/null; then echo "batch: ACTIVE (pid $(pgrep -f 'ruby.sh$' | head -1))"
else echo "batch: NOT running"; fi
pgrep -a ffmpeg | grep -q hevc_vaapi && echo "encoder: ACTIVE" || echo "encoder: idle"
echo
echo "=== PROGRESS ==="
printf "completed: %s files\n" "$(wc -l < state/done.list 2>/dev/null)"
printf "failed:    %s files\n" "$(wc -l < state/failed.list 2>/dev/null)"
echo
echo "=== SPACE FREED so far (from log) ==="
awk -F'saved ' '/DONE:/{print $2}' ruby.log 2>/dev/null | awk '{print $1}' | sed 's/B$//' | \
  numfmt --from=iec 2>/dev/null | awk '{s+=$1} END{printf "%s across %d files\n", (s? sprintf("%.1f GB",s/1e9):"0"), NR}'
echo
echo "=== 16TB drive free space ==="; df -h /mnt/disks/16TBSeagate | tail -1
echo
echo "=== current file ==="; tail -1 ruby.log
echo
echo "Controls:"
echo "  Pause/stop:  pkill -f ruby.sh; pkill -f hevc_vaapi"
echo "  Resume:      cd /home/naboo/ruby && nohup ./ruby.sh > batch.out 2>&1 &"
echo "  Watch live:  tail -f /home/naboo/ruby/ruby.log"
echo "  Failures:    cat /home/naboo/ruby/state/failed.list"
