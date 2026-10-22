# install/lib/log.sh — 紀錄：畫面與 ~/install-logs/<時間>-<步驟>.log 各一份
# 規則：密碼永遠不進 log（步驟把密碼讀進變數或檔案，不放在指令列）。

LOG_DIR=${LOG_DIR:-$HOME/install-logs}
STEP_NAME=${STEP_NAME:-$(basename "${BASH_SOURCE[-1]}" .sh)}
mkdir -p "$LOG_DIR"
LOG_FILE=$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$STEP_NAME.log

log()     { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$LOG_FILE"; }
section() { log "== $*"; }
ok()      { log "ok   $*"; }
warn()    { log "WARN $*"; }
fail()    { log "FAIL $*"; FAILED=$((${FAILED:-0} + 1)); }
die()     { log "FAIL $*"; log "停在 $STEP_NAME；log：$LOG_FILE"; exit 1; }

# 執行一條指令，輸出同時進 log；回傳指令本身的 rc
run() { log "\$ $*"; "$@" 2>&1 | tee -a "$LOG_FILE"; return "${PIPESTATUS[0]}"; }

# 銀行的步驟：只印「請銀行做」，不代做
bank() {
  log "---- 請銀行做 ----"
  local line; for line in "$@"; do log "  $line"; done
  log "-------------------"
}

# 等銀行完成才能繼續：rc 2，install.sh 看到會停下來並提示重跑
pending() { log "等銀行完成以上事項後重跑：bash $0"; exit 2; }

# 收尾：有任何 fail 就 die
finish() {
  if [ "${FAILED:-0}" -gt 0 ]; then die "$STEP_NAME：$FAILED 項未通過"; fi
  log "$STEP_NAME 完成；log：$LOG_FILE"
  touch "$LOG_DIR/$STEP_NAME.done"
}
