# install/lib/log.sh —— 畫面與紀錄檔的輸出
#
# 每支步驟都 source 這個檔。輸出同時寫到畫面與 ~/install-logs/<時間>-<步驟名>.log。
# 規則：密碼永遠不進輸出（步驟把密碼讀進變數或 0600 檔，不放在要印出來的字串裡）。
#
#   section  "說明"            印一個小節標題，對應手把手文件的小節（例如 "10.2 設定檔"）
#   log      "訊息"            一般訊息
#   ok       "訊息"            一項檢查通過
#   warn     "訊息"            值得注意但不擋流程
#   fail     "訊息"            一項檢查沒過；累計在 FAIL_COUNT，最後由 finish_step 決定這站成不成功
#   die      "訊息"            立刻停止這支步驟（rc 1）
#   ask_bank "第一行" "第二行" …  印出「請銀行做」清單（我方不代做；空字串的行會略過）
#   wait_for_bank             銀行還沒做完：停止這支步驟（rc 2）；install.sh 看到 rc 2 會提示做完後重跑
#   finish_step               收尾：有 fail 就 die；全部通過就寫 <步驟名>.done 標記（install.sh --list 看這個）

LOG_DIR=${LOG_DIR:-$HOME/install-logs}
STEP_NAME=${STEP_NAME:-$(basename "${BASH_SOURCE[-1]}" .sh)}   # 呼叫這個 lib 的步驟檔名，例如 10-kafka
mkdir -p "$LOG_DIR"
LOG_FILE=$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$STEP_NAME.log
FAIL_COUNT=0

log()     { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$LOG_FILE"; }
section() { log "== $*"; }
ok()      { log "ok   $*"; }
warn()    { log "WARN $*"; }
fail()    { log "FAIL $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
die()     { log "FAIL $*"; log "停在 $STEP_NAME；紀錄檔：$LOG_FILE"; exit 1; }

ask_bank() {
  local line
  log "---- 請銀行做 ----"
  for line in "$@"; do
    [ -n "$line" ] && log "  $line"
  done
  log "-------------------"
}

wait_for_bank() {
  log "等銀行完成以上事項後重跑：bash $0"
  exit 2
}

finish_step() {
  [ "$FAIL_COUNT" -gt 0 ] && die "$STEP_NAME：$FAIL_COUNT 項未通過"
  log "$STEP_NAME 完成；紀錄檔：$LOG_FILE"
  touch "$LOG_DIR/$STEP_NAME.done"
}
