#!/bin/bash
# Variables assigned here are read by the sourced plugin functions.
# shellcheck disable=SC2034
S="$(dirname "$0")/../worklog.30m.sh"
fail=0
ok(){ echo "PASS $1"; }
no(){ echo "FAIL $1: $2"; fail=1; }

# Keep the run hermetic: never read the developer's real config or state dir.
export JIRA_WORKLOG_NUDGE_CONFIG=/dev/null
STATE_DIR=$(mktemp -d); export STATE_DIR
tmp=$(mktemp)
trap 'rm -rf "$STATE_DIR" "$tmp"' EXIT

# unit: source funcs without running main
sed -n '1,/^if \[ "\${1:-}" = "--refresh" \]/p' "$S" | sed '$d' > "$tmp"
# shellcheck source=/dev/null
. "$tmp"; set +o pipefail

[ "$(hhmm 7920)" = "2h12" ] && ok hhmm || no hhmm "got $(hhmm 7920)"
[ "$(hhmm 0)" = "0h00" ] && ok hhmm-zero || no hhmm-zero "got $(hhmm 0)"
[ "$(short 3600)" = "1h" ] && [ "$(short 5400)" = "1h30" ] && ok short || no short "got $(short 3600)/$(short 5400)"
[ "$(echo '[FE] Do the thing [2h]' | tidy)" = "Do the thing" ] && ok tidy || no tidy "got $(echo '[FE] Do the thing [2h]' | tidy)"
[ "$(epoch_of 2026-08-28T15:44:00+0600)" = 1787910240 ] && ok epoch_of || no epoch_of "got $(epoch_of 2026-08-28T15:44:00+0600)"
[ -z "$(epoch_of 'garbage')" ] && ok epoch_of-bad || no epoch_of-bad "not empty"

# render: gated when logged >= 5h
out=$(render $(( $(date +%s) - 99999 )) 18000 $'BX-1\tx')
[ "$(echo "$out" | head -1)" = "⏱ | color=#808080" ] && echo "$out" | grep -q 'param1=[^ ]*BX-1' && ok gate-hours || no gate-hours "$out"

# render: gated when elapsed < 2h
render $(( $(date +%s) - 7000 )) 0 $'BX-1\tx' | head -1 | grep -q '^⏱ | color' && ok gate-elapsed || no gate-elapsed "title not dim"

# render: nudge at >= 2h
o=$(render $(( $(date +%s) - 7260 )) 0 $'BX-1\tsummary here\t0\t0\nBX-2\tanother\t5400\t7200')
big=""; for i in 1 2 3 4 5 6 7; do big+="BX-$i"$'\t'"s$i"$'\t0\t0\n'; done
sub=$(render $(( $(date +%s) - 7260 )) 0 "$big")
[ "$(echo "$sub" | grep -c '^--BX-')" = 2 ] && ok submenu-overflow || no submenu-overflow "$(echo "$sub"|grep -c '^--BX-') nested"
echo "$sub" | grep -q '^More tickets$' && ok submenu-header || no submenu-header "no header"
[ "$(echo "$sub" | grep -c '^BX-')" = 5 ] && ok submenu-top5 || no submenu-top5 "$(echo "$sub"|grep -c '^BX-') top-level"
echo "$o" | head -1 | grep -q '^⏱ 2h01$' && ok nudge-title || no nudge-title "$(echo "$o"|head -1)"
echo "$o" | grep -q 'BX-1  summary here — 0h of 0h | bash=.*param1=.*BX-1' && ok row-format || no row-format "$o"
echo "$o" | grep -q '^Sprint 1h30 of 2h estimated$' && ok sprint-totals || no sprint-totals "$(echo "$o"|grep Sprint)"
echo "$o" | grep -q 'Refresh | refresh=true' && ok refresh-row || no refresh-row ""
echo "$o" | grep -q 'Quit SwiftBar' && ok quit-row || no quit-row ""

WORKDAY_START=09:00
ds=$(date -j -f '%Y-%m-%d %H:%M' "$(date +%Y-%m-%d) 09:00" +%s)
yesterday_evening=$(( ds - 16 * 3600 ))
[ "$(render "$yesterday_evening" 0 $'BX-1\tx\t0\t0' | head -1)" = "⏱ $(hhmm $(( $(date +%s) - ds )))" ] && ok clamps-overnight || no clamps-overnight "not clamped"
render "$yesterday_evening" 0 $'BX-1\tx\t0\t0' | grep -q 'unlogged since 09:00' && ok clamp-label || no clamp-label "label not clamped"
[ "$(render $(( $(date +%s) - 600 )) 0 $'BX-1\tx\t0\t0' | head -1)" = "⏱ | color=#808080" ] && ok no-clamp-today || no no-clamp-today "clamped a same-day slice"

y=$(date -v-1d +%Y-%m-%d)
ds=$(printf '%s\t3600\n' "$y")
o2=$(day_submenu "Last 2" "$y" "$ds")
[ "$(echo "$o2" | head -1)" = "Last 2 — 1h over 2 days" ] && ok daysub-header || no daysub-header "$(echo "$o2"|head -1)"
[ "$(echo "$o2" | grep -c '^--')" = 2 ] && ok daysub-fills-gaps || no daysub-fills-gaps "$(echo "$o2"|grep -c '^--')"
echo "$o2" | tail -1 | grep -q '· 0h$' && ok daysub-zero-day || no daysub-zero-day "$(echo "$o2"|tail -1)"

# no unquoted param with spaces (the iTerm bug)
echo "$o" | grep -E '^BX-1 ' | grep -qE 'param1=[^ ]+ terminal=false$' && ok param-no-split || no param-split "ticket row has split param"



ALERTS="$STATE_DIR/alerts-$(date +%Y-%m-%d)"
ALERT_AFTER_SECONDS=10800; ALERT_MAX_PER_DAY=3; ALERT_LAST_HOUR=23; DAILY_TARGET_SECONDS=18000

should_alert 7200 0 && no alert-under-threshold "fired below 3h" || ok alert-under-threshold
should_alert 20000 18000 && no alert-target-met "fired after target reached" || ok alert-target-met
should_alert 20000 0 && ok alert-first || no alert-first "did not fire"
should_alert 20000 0 && no alert-throttled "fired twice in a row" || ok alert-throttled
printf '1 0\n' > "$ALERTS"; should_alert 20000 0 && ok alert-second || no alert-second "blocked"
printf '3 0\n' > "$ALERTS"; should_alert 20000 0 && no alert-daily-cap "exceeded 3/day" || ok alert-daily-cap
printf '0 0\n' > "$ALERTS"; ALERT_LAST_HOUR=0; should_alert 20000 0 && no alert-after-hours "fired past cutoff" || ok alert-after-hours
rm -f "$ALERTS"

# slice_end: the last *ending* slice wins, not the last *starting* one
s1=$'2026-08-28T09:00:00+0600 14400\n2026-08-28T10:00:00+0600 1800'
[ "$(slice_end "$s1")" = "$(( $(epoch_of 2026-08-28T09:00:00+0600) + 14400 ))" ] && ok slice-end-longest || no slice-end-longest "got $(slice_end "$s1")"
# slice_end: offsets are compared as instants, not as strings (15:00+0600 is 09:00Z, before 12:00Z)
s2=$'2026-08-28T12:00:00+0000 600\n2026-08-28T15:00:00+0600 600'
[ "$(slice_end "$s2")" = "$(( $(epoch_of 2026-08-28T12:00:00+0000) + 600 ))" ] && ok slice-end-tz || no slice-end-tz "got $(slice_end "$s2")"

# refresh_cache: a failed write must not clobber the last good cache
all_slices() { printf '%s 3600\n' "$(date '+%Y-%m-%dT10:00:00%z')"; }
candidates() { printf 'BX-1\tx\t0\t0\n'; }
sprint_window() { :; }
echo '{"end":"1","logged":"0","cands":"BX-9\tkeep"}' > "$CACHE"
jq() { printf '{"end":'; return 1; }
refresh_cache
unset -f jq
[ "$(jq -r .cands "$CACHE" 2>/dev/null)" = $'BX-9\tkeep' ] && ok cache-atomic || no cache-atomic "cache is now: $(cat "$CACHE")"
refresh_cache
[ "$(jq -r .cands "$CACHE" 2>/dev/null)" = $'BX-1\tx\t0\t0' ] && ok cache-written || no cache-written "cache is now: $(cat "$CACHE")"

# refresh_cache: a second refresh while one is running does not start another fan-out
mkdir -p "$STATE_DIR/refresh.lock"
all_slices() { touch "$STATE_DIR/fanout-ran"; }
refresh_cache
[ ! -e "$STATE_DIR/fanout-ran" ] && ok refresh-lock || no refresh-lock "second fan-out started while locked"
rm -rf "$STATE_DIR/refresh.lock" "$STATE_DIR/fanout-ran"
refresh_cache
[ -e "$STATE_DIR/fanout-ran" ] && [ ! -d "$STATE_DIR/refresh.lock" ] && ok refresh-unlocks || no refresh-unlocks "did not run or left the lock behind"

# main: the notification uses the same workday clamp as the title.
# Last slice ended yesterday evening, the workday started just now: no alert.
P=$(mktemp -d)
cfg="$P/config.env"
printf 'JIRA_SITE=x.atlassian.net\nJIRA_EMAIL=me@x\nWORKDAY_START=%s\nALERT_LAST_HOUR=23\nSTATE_DIR=%s\n' "$(date +%H:%M)" "$P" > "$cfg"
printf '{"end":"%s","logged":"0","cands":"BX-1\\tx\\t0\\t0"}' $(( $(date +%s) - 20 * 3600 )) > "$P/cache.json"
JIRA_WORKLOG_NUDGE_CONFIG="$cfg" bash "$S" > "$P/out" 2>/dev/null
head -1 "$P/out" | grep -q '^⏱ | color' && ok morning-title-quiet || no morning-title-quiet "$(head -1 "$P/out")"
[ ! -e "$P/alerts-$(date +%Y-%m-%d)" ] && ok morning-no-alert || no morning-no-alert "notified about overnight gap"
sleep 1; rm -rf "$P"

I="$(dirname "$0")/../install.sh"
bash -n "$I" && ok installer-syntax || no installer-syntax "syntax error"
grep -q 'brew install --cask swiftbar' "$I" && ok installer-swiftbar || no installer-swiftbar "no swiftbar install"
grep -q 'acli jira auth login' "$I" && ok installer-login || no installer-login "no login step"
grep -q 'open -a SwiftBar' "$I" && ok installer-starts-app || no installer-starts-app "does not start app"

exit $fail
