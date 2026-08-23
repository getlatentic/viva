#!/bin/sh
# Is it off-peak for DeepSeek right now? Exit 0 if yes.
#
#     . tools/offpeak.sh && offpeak_or_refuse
#
# ONE PLACE, because the rule changed and two scripts carried their own copy of
# the old one. From 2026-08-23 the whole WEEKEND is off-peak in Beijing time,
# on top of the daily off-peak hours -- and a guard that still refuses on a
# Sunday costs a day of work for a rule that no longer exists.
#
# Beijing is UTC+8, so the weekend runs from Friday 16:00 UTC to Sunday 16:00
# UTC. Computing it from the Beijing-time day rather than hard-coding those
# hours keeps it right when somebody reads it in another timezone.
#
# Peak, on a weekday, is 00:30-08:30 Beijing = 16:30-00:30 UTC. The daily rule
# this project has used -- refuse 01:00-04:00 and 06:00-10:00 UTC -- is kept as
# the conservative weekday guard rather than widened here; narrowing a spend
# guard is not a thing to do as a side effect.
offpeak_reason() {
  beijing_day=$(TZ=Asia/Shanghai date +%u)      # 1 Monday .. 7 Sunday
  hour=$(date -u +%H)
  if [ "$beijing_day" -ge 6 ]; then
    printf 'weekend in Beijing time (day %s); off-peak all day\n' "$beijing_day"
    return 0
  fi
  case "$hour" in
    0[1-3]|0[6-9]) printf 'PEAK WINDOW (%s:00 UTC on a weekday)\n' "$hour"; return 1 ;;
  esac
  printf 'off-peak hour (%s:00 UTC)\n' "$hour"
  return 0
}

offpeak_or_refuse() {
  reason=$(offpeak_reason) && { printf '%s\n' "$reason"; return 0; }
  printf '%s. Off-peak is mandatory; not running.\n' "$reason" >&2
  return 1
}
