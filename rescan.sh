#!/usr/bin/env bash
#
# rescan.sh — monthly refresh of the compression to-do list.
#
# 1. Re-scans ROOTS and regenerates state/plan.tsv (a read-only PLAN_OUT pass:
#    marks each file DONE / CONVERT / SKIP — no encoding happens here).
# 2. (Re)starts ruby.service so any newly-added 4K remuxes get
#    converted. If the encoder is already running this is a harmless no-op;
#    the encoder self-skips files already in state/done.list.
#
# Wired to ruby-rescan.timer (monthly). Safe to run by hand anytime.
#
set -uo pipefail
BASE=/home/naboo/ruby
STATE="$BASE/state"
PLAN="$STATE/plan.tsv"

# fresh snapshot — plan() appends, so truncate first
: > "$PLAN"
PLAN_OUT="$PLAN" LOG="$BASE/plan.log" "$BASE/ruby.sh" >/dev/null 2>&1 || true

todo=$(grep -c '^CONVERT'$'\t' "$PLAN" 2>/dev/null || echo 0)
done=$(grep -c '^DONE'$'\t' "$PLAN" 2>/dev/null || echo 0)
echo "[$(date '+%F %T')] rescan: plan refreshed — ${todo} to convert, ${done} already done" >> "$BASE/ruby.log"

# kick the encoder (no-op if already active)
systemctl start ruby.service
