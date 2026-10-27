#!/usr/bin/env bash
# scan-log.sh <run-chapter 產生的執行紀錄>…：找出「rc 是 0 但其實失敗」的輸出
#
# 手把手的很多指令是迴圈或 echo 組成的檢查，失敗時印出錯誤字樣、結束碼卻是 0（例如 2026-10-24 全書重跑：
# AD 測試帳號沒建成，之後每個「alice login」都是 401，整份紀錄卻全是 rc=0）。跑完一定要用這支掃一次。
#
# 印出：非 0 的 rc／STOP、可疑的輸出行（前面標是哪一塊）。可疑字樣都是「預期外」的；文件本來就預期會被拒的
# 反向測試（→ 401、被拒、AuthorizationException、TLS 直接拒絕…）先排除。結束碼：0 沒有可疑、1 有。
[ $# -ge 1 ] || { echo "用法：bash $0 <紀錄檔>…"; exit 2; }

SUSPICIOUS='a password is required|Permission denied|FAIL |FAIL$|MDS=000|REST=000|UI=000|=000 |驗不過|No such file|ERROR|Error:|登入失敗|login: 401|login after [a-z ]*: 401|AUTH_FAIL|MISMATCH|=DIFF|=OLD|chain=FAIL|missing operand|command not found|syntax error|unexpected EOF|Traceback|Connection refused|timed out|沒有回應|STOP at'
# 檢查的標籤後面沒有值（「alice 建 topic：」後面空白＝指令沒有輸出，多半是前提不成立）：不受下面的排除影響
EMPTY_VALUE='：[[:space:]]*$'
# 反向測試與已知無害的訊息（新增排除前先確認那行在文件裡就是預期輸出）
EXPECTED='anon=401|→ 401|other-cert=401|no-cert=000|TLS 直接拒絕|（應被拒）|被拒|AuthorizationException|DENIED +x[0-9]|ignore[.]partial[.]result|LDAP_BIND_PASSWORD|讀訊息：|建 topic：|改 role binding：|^ok   |Permission denied (publickey)|ProblemSeverity'

status=0
for log in "$@"; do
  echo "== $log"
  bad_rc=$(grep -cE '===== rc=[1-9]|^STOP at' "$log")
  blocks=$(grep -c '^===== BLOCK' "$log"); passed=$(grep -c '===== rc=0' "$log"); skipped=$(grep -c '^===== BLOCK .* skipped' "$log")
  echo "   塊：$blocks（rc=0 $passed、略過 $skipped、失敗 $bad_rc）"
  [ "$bad_rc" = 0 ] || { grep -E '===== rc=[1-9]|^STOP at' "$log" | head -5 | sed 's/^/   /'; status=1; }
  hits=$(awk -v s="$SUSPICIOUS" -v e="$EXPECTED" -v v="$EMPTY_VALUE" '
    /^===== BLOCK/ { block = substr($0, 13, 70); next }
    /^===== rc=/   { next }
    $0 ~ v { printf "   %s | %s（冒號後沒有值）\n", block, substr($0, 1, 140); next }
    $0 ~ s && $0 !~ e { printf "   %s | %s\n", block, substr($0, 1, 140) }' "$log")
  if [ -n "$hits" ]; then echo "   可疑的輸出（rc 可能是 0）："; echo "$hits" | head -40; status=1; else echo "   沒有可疑的輸出"; fi
done
exit $status
