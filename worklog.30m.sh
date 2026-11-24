#!/bin/bash
set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

CONFIG="${JIRA_WORKLOG_NUDGE_CONFIG:-$HOME/.config/jira-worklog-nudge/config.env}"
# shellcheck source=config.env.example
[ -f "$CONFIG" ] && . "$CONFIG"

: "${JIRA_SITE:=}"
: "${JIRA_EMAIL:=}"
: "${DAILY_TARGET_HOURS:=5}"
: "${NUDGE_AFTER_HOURS:=2}"
: "${ALERT_AFTER_HOURS:=3}"
: "${ALERT_MAX_PER_DAY:=3}"
: "${ALERT_LAST_HOUR:=20}"
: "${MAX_ROWS:=5}"
: "${WORKDAY_START:=09:00}"
: "${STATE_DIR:=$HOME/.local/state/jira-worklog-nudge}"
: "${LOG_COMMAND:=}"

mkdir -p "$STATE_DIR"
CACHE="$STATE_DIR/cache.json"
ALERTS="$STATE_DIR/alerts-$(date +%Y-%m-%d)"
DAILY_TARGET_SECONDS=$(( DAILY_TARGET_HOURS * 3600 ))
NUDGE_AFTER_SECONDS=$(( NUDGE_AFTER_HOURS * 3600 ))
ALERT_AFTER_SECONDS=$(( ALERT_AFTER_HOURS * 3600 ))

keys_with_worklogs() {
  acli jira workitem search --jql "worklogAuthor = currentUser() AND worklogDate >= $1" --json 2>/dev/null \
    | jq -r '.[]?.key' 2>/dev/null
}

all_slices() {
  local f
  f=$(mktemp)
  printf '%s' '(if (.fields.worklog.total // 0) > 20 then "TRUNCATED 0" else empty end), (.fields.worklog.worklogs[]? | select(.author.emailAddress==$me) | "\(.started|sub("[.][0-9]+";"")) \(.timeSpentSeconds)")' > "$f"
  keys_with_worklogs '-14d' \
    | JQ_FILTER="$f" ME="$JIRA_EMAIL" xargs -P 8 -I{} sh -c \
      'acli jira workitem view "$1" --fields worklog --json 2>/dev/null | jq -r --arg me "$ME" -f "$JQ_FILTER"' _ {}
  rm -f "$f"
}

start_of_today() { date '+%Y-%m-%dT00:00:00%z'; }

epoch_of() { date -j -f '%Y-%m-%dT%H:%M:%S%z' "$1" +%s 2>/dev/null; }

# Latest end (started + timeSpentSeconds) over all slices, compared as epochs so a
# long early slice beats a short later one and mixed UTC offsets sort correctly.
slice_end() {
  local slices=$1 started secs e best=""
  echo "$slices" | grep -q TRUNCATED && { epoch_of "$(start_of_today)"; return; }
  while read -r started secs; do
    [ -z "$started" ] && continue
    e=$(epoch_of "$started") || continue
    [ -z "$e" ] && continue
    e=$(( e + ${secs:-0} ))
    if [ -z "$best" ] || [ "$e" -gt "$best" ]; then best=$e; fi
  done <<< "$slices"
  if [ -z "$best" ]; then epoch_of "$(start_of_today)"; else echo "$best"; fi
}

logged_on() { echo "$1" | awk -v d="$2" 'index($1,d)==1 {t+=$2} END{print t+0}'; }

day_totals_from() {
  echo "$1" | grep -v TRUNCATED \
    | awk '{d[substr($1,1,10)]+=$2} END{for (k in d) print k"\t"d[k]}' | sort -r
}


candidates() {
  local out tmp
  out=$(acli jira workitem search --jql "assignee = currentUser() AND sprint in openSprints() AND statusCategory != Done" --fields summary --json 2>/dev/null \
        | jq -r '.[]? | "\(.key)\t\(.fields.summary)"' 2>/dev/null)
  [ -z "$out" ] && out=$(acli jira workitem search --jql "assignee = currentUser() AND statusCategory = 'In Progress'" --fields summary --json 2>/dev/null \
        | jq -r '.[]? | "\(.key)\t\(.fields.summary)"' 2>/dev/null)
  tmp=$(mktemp)
  echo "$out" | cut -f1 | xargs -P 8 -I{} sh -c \
    'acli jira workitem view {} --fields timespent,timeoriginalestimate --json 2>/dev/null | jq -r "\"{}\\t\\(.fields.timespent // 0)\\t\\(.fields.timeoriginalestimate // 0)\""' > "$tmp"
  awk -F'\t' 'NR==FNR{sp[$1]=$2;es[$1]=$3;next} {print $1"\t"$2"\t"(sp[$1]+0)"\t"(es[$1]+0)}' "$tmp" <(echo "$out")
  rm -f "$tmp"
}


sprint_window() {
  acli jira workitem view "$1" --fields customfield_10020 --json 2>/dev/null \
    | jq -r '.fields.customfield_10020[]? | select(.state=="active") | "\(.startDate[0:10])\t\(.endDate[0:10])"' 2>/dev/null | head -1
}

hhmm() { printf '%dh%02d' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )); }

short() {
  local h=$(( $1 / 3600 )) m=$(( ($1 % 3600) / 60 ))
  if [ "$m" = 0 ]; then echo "${h}h"; else printf '%dh%02d\n' "$h" "$m"; fi
}

tidy() { sed -E 's/^\[[A-Za-z]+\] *//; s/ *\[[0-9]+(\.[0-9]+)?h\] *$//'; }

open_url() { echo "/usr/bin/open"; }

log_target() {
  if [ -n "$LOG_COMMAND" ]; then echo "$LOG_COMMAND"; else open_url; fi
}

log_param() {
  if [ -n "$LOG_COMMAND" ]; then echo "$1"; else echo "https://$JIRA_SITE/browse/$1"; fi
}

should_alert() {
  local elapsed=$1 logged=$2 count last hour
  [ "$elapsed" -lt "$ALERT_AFTER_SECONDS" ] && return 1
  [ "$logged" -ge "$DAILY_TARGET_SECONDS" ] && return 1
  hour=$(date +%H)
  [ "${hour#0}" -gt "$ALERT_LAST_HOUR" ] && return 1
  count=0; last=0
  [ -f "$ALERTS" ] && read -r count last < "$ALERTS"
  [ "$count" -ge "$ALERT_MAX_PER_DAY" ] && return 1
  [ $(( $(date +%s) - last )) -lt "$ALERT_AFTER_SECONDS" ] && return 1
  echo "$(( count + 1 )) $(date +%s)" > "$ALERTS"
  return 0
}

day_submenu() {
  local title=$1 since=$2 days=$3 cur secs total=0 n=0 body="" today
  today=$(date +%Y-%m-%d)
  cur=$since
  while [ ! "$cur" \> "$today" ]; do
    secs=$(echo "$days" | awk -F'\t' -v d="$cur" '$1==d{print $2}')
    secs=${secs:-0}
    body+="--$(date -j -f %Y-%m-%d "$cur" '+%a %d %b') · $(short "$secs")"$'\n'
    total=$(( total + secs ))
    n=$(( n + 1 ))
    cur=$(date -j -v+1d -f %Y-%m-%d "$cur" +%Y-%m-%d)
  done
  echo "$title — $(short $total) over $n days"
  printf '%s' "$body"
}

menu_controls() {
  echo "---"
  echo "Restart SwiftBar | bash=/bin/sh param1=-c param2=\"(sleep 1; open -a SwiftBar) & killall SwiftBar\" terminal=false"
  echo "Quit SwiftBar | bash=/usr/bin/killall param1=SwiftBar terminal=false"
}

# Never count back past WORKDAY_START today: a gap that began last night starts at 09:00.
clamp_end() {
  local end=$1 day_start
  day_start=$(date -j -f '%Y-%m-%d %H:%M' "$(date +%Y-%m-%d) $WORKDAY_START" +%s 2>/dev/null)
  if [ -n "$day_start" ] && [ "$end" -lt "$day_start" ]; then echo "$day_start"; else echo "$end"; fi
}

render() {
  local end logged=$2 cands=$3 days=${4:-} sprint=${5:-} elapsed key summary
  end=$(clamp_end "$1")
  elapsed=$(( $(date +%s) - end ))
  [ "$elapsed" -lt 0 ] && elapsed=0
  if [ "$logged" -ge "$DAILY_TARGET_SECONDS" ] || [ "$elapsed" -lt "$NUDGE_AFTER_SECONDS" ]; then
    echo "⏱ | color=#808080"
  else
    echo "⏱ $(hhmm "$elapsed")"
  fi
  echo "---"
  echo "Logged today $(hhmm "$logged") · unlogged since $(date -r "$end" '+%H:%M')"
  local spent est spent_total=0 est_total=0 shown=0 rows="" prefix
  while IFS=$'\t' read -r key summary spent est; do
    [ -z "$key" ] && continue
    spent_total=$(( spent_total + ${spent:-0} ))
    est_total=$(( est_total + ${est:-0} ))
    prefix=""
    [ "$shown" -ge "$MAX_ROWS" ] && prefix="--"
    rows+="$prefix$key  $(echo "$summary" | tidy) — $(short "${spent:-0}") of $(short "${est:-0}") | bash=$(log_target) param1=$(log_param "$key") terminal=false"$'\n'
    shown=$(( shown + 1 ))
    [ "$shown" = "$MAX_ROWS" ] && rows+="More tickets"$'\n'
  done <<< "$cands"
  echo "Sprint $(short $spent_total) of $(short $est_total) estimated"
  echo "---"
  printf '%s' "$rows"
  if [ -n "$days" ]; then
    day_submenu "Last 7 days" "$(date -v-6d +%Y-%m-%d)" "$days"
    local sprint_start=${sprint%%$'\t'*}
    [ -n "$sprint_start" ] && day_submenu "This sprint since $sprint_start" "$sprint_start" "$days"
    echo "---"
  fi
  echo "Refresh | refresh=true"
  menu_controls
}

refresh_cache() {
  local end logged cands days sprint slices tmp lock="$STATE_DIR/refresh.lock"
  # One fan-out at a time; a lock older than 10 minutes is from a killed run.
  find "$lock" -maxdepth 0 -mmin +10 -exec rmdir {} \; 2>/dev/null
  mkdir "$lock" 2>/dev/null || return 0
  slices=$(all_slices)
  end=$(slice_end "$slices")
  logged=$(logged_on "$slices" "$(date +%Y-%m-%d)")
  cands=$(candidates)
  days=$(day_totals_from "$slices")
  sprint=$(sprint_window "$(echo "$cands" | head -1 | cut -f1)")
  # Write beside the cache and rename, so a failed write never truncates the last
  # good cache and a concurrent render never reads half a file.
  if [ -n "$end" ] && [ -n "$cands" ] && tmp=$(mktemp "$STATE_DIR/cache.XXXXXX"); then
    if jq -n --arg end "$end" --arg logged "$logged" --arg cands "$cands" \
         --arg days "$days" --arg sprint "$sprint" \
         '{end:$end,logged:$logged,cands:$cands,days:$days,sprint:$sprint}' > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$CACHE"
    else
      rm -f "$tmp"
    fi
  fi
  rmdir "$lock" 2>/dev/null
  return 0
}

if [ "${1:-}" = "--refresh" ]; then
  refresh_cache
  exit 0
fi

if [ -z "$JIRA_SITE" ] || [ -z "$JIRA_EMAIL" ]; then
  echo "⏱ ⚙"
  echo "---"
  echo "Set JIRA_SITE and JIRA_EMAIL in $CONFIG"
  menu_controls
  exit 0
fi

if [ ! -s "$CACHE" ]; then
  echo "⏱ …"
  menu_controls
  "$0" --refresh >/dev/null 2>&1 &
  exit 0
fi

end=$(jq -r '.end' "$CACHE")
logged=$(jq -r '.logged' "$CACHE")
render "$end" "$logged" "$(jq -r '.cands' "$CACHE")" \
  "$(jq -r '.days // ""' "$CACHE")" "$(jq -r '.sprint // ""' "$CACHE")"

if should_alert $(( $(date +%s) - $(clamp_end "$end") )) "$logged"; then
  /usr/bin/osascript -e 'display notification "Nothing logged for '"$ALERT_AFTER_HOURS"'h" with title "Worklog nudge"' >/dev/null 2>&1
fi

"$0" --refresh >/dev/null 2>&1 &
