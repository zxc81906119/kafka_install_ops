#!/usr/bin/env bash
# 測變更時窗（core_window_ok）：跨午夜的時窗、跨週末的星期範圍、剛好在邊界的那一分鐘、"*"、沒設時窗。
# 不需要叢集。時間用 OPMENU_NOW_OVERRIDE="<星期 1-7> <HH:MM>" 指定（只有 OPMENU_ALLOW_ENV_OVERRIDE=1 時才生效）。
#   ./test-change-window.sh      全部通過印 "ALL PASS",有失敗回傳 1
cd "$(dirname "$0")/.." || exit 1
export OPMENU_HOME="$PWD" OPMENU_LOG="$(mktemp)" OPMENU_SYSLOG=0 OPMENU_ALLOW_ENV_OVERRIDE=1
. lib/defaults.sh
. lib/common.sh

fails=0

# expect <時窗設定> <星期 時:分> <in|out> <說明>
expect() {
  local window="$1" now="$2" want="$3" what="$4" got

  OPMENU_CHANGE_WINDOW="$window"
  OPMENU_NOW_OVERRIDE="$now"

  if core_window_ok; then
    got=in
  else
    got=out
  fi

  if [ "$got" = "$want" ]; then
    echo "ok   - $what"
  else
    echo "FAIL - $what（時窗 '$window'，時間 $now：要 $want，得到 $got）"
    fails=$((fails + 1))
  fi
}

W='Mon-Fri 22:00-06:00;Sat,Sun 00:00-23:59'
expect "$W" "1 23:00" in  "週一 23:00：在週一晚上的時窗內"
expect "$W" "2 05:00" in  "週二 05:00：跨午夜，屬於週一晚上開始的時窗"
expect "$W" "1 05:00" out "週一 05:00：前一天週日不在 Mon-Fri，週一也不在 Sat,Sun"
expect "$W" "3 12:00" out "週三中午：不在時窗"
expect "$W" "6 12:00" in  "週六中午：週末整天"
expect "$W" "6 03:00" in  "週六 03:00：週五晚上開始的時窗延伸過來"
expect "$W" "1 22:00" in  "週一 22:00：開始那一分鐘算在內"
expect "$W" "2 06:00" in  "週二 06:00：結束那一分鐘算在內"
expect "$W" "1 06:00" out "週一 06:00：前一天週日不在 Mon-Fri"

expect '1-5 09:00-17:00' "3 09:00" in  "數字星期：週三 09:00"
expect '1-5 09:00-17:00' "3 17:00" in  "數字星期：週三 17:00（結束那一分鐘）"
expect '1-5 09:00-17:00' "3 17:01" out "數字星期：週三 17:01"
expect '1-5 09:00-17:00' "7 10:00" out "數字星期：週日"

expect '* 08:00-09:00' "4 08:30" in  "每天：週四 08:30"
expect '* 08:00-09:00' "4 09:30" out "每天：週四 09:30"

expect 'Fri-Mon 10:00-11:00' "7 10:30" in  "跨週末的星期範圍：週日"
expect 'Fri-Mon 10:00-11:00' "3 10:30" out "跨週末的星期範圍：週三"

expect ' Mon-Fri 22:00-06:00 ; Sat,Sun 00:00-23:59 ' "6 12:00" in "分號前後有空白也認得"

expect '' "3 12:00" in "沒設時窗：不限制"

rm -f "$OPMENU_LOG"

if [ $fails -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$fails 項失敗"
  exit 1
fi
