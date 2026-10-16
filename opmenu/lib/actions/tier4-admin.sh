# 第四層:授權與緊急。41–43 以操作者本人的 token 呼叫 MDS;91 用 bootstrap certificate(由 backend 保管)。所有輸入先過 lib/validate.sh

_show_mds() { # 印出 MDS 回應(去掉最後的 HTTP 狀態列);狀態不是 2xx 時回傳 1,讓 core 依原始輸出判斷是被拒還是失敗
  local out; out="$(be_mds "$@")"; printf '%s\n' "$out" | sed '$d'; printf '%s\n' "$out" | _http_ok; }
_roles_of() { _show_mds POST "/security/1.0/lookup/principals/$1/roleNames" "$(_scope)"; }

reg 41 4 n n "查看權限" "輸入 AD 群組或帳號,列出它的 role binding 與資源(需 SecurityAdmin 或 UserAdmin)"
act_41() {
  local p="${1:-}"; [ -n "$p" ] || read -r -p "principal(例 Group:ops 或 User:svc-orders): " p
  v_principal "$p" || return 1
  echo "-- cluster 層級的 role:"; _roles_of "$p" || return 1
  echo "-- 資源層級的 binding:"; _show_mds POST "/security/1.0/lookup/rolebindings/principal/$p" "$(_scope)"
}

reg 42 4 y y "指派或移除權限" "只能綁 AD 群組,不能綁個人;可指派的 role 限於 OPMENU_ROLES_ALLOWED"
act_42() {
  local op="${1:-}" g="${2:-}" role="${3:-}" rtype="${4:-}" rname="${5:-}"
  [ -n "$op" ] || read -r -p "動作(add | remove): " op; [ -n "$g" ] || read -r -p "AD 群組(不含 Group:): " g; [ -n "$role" ] || read -r -p "role(例 DeveloperRead、Operator): " role
  v_in "$op" "add remove" "動作" || return 1; v_adgroup "$g" || return 1; v_role "$role" || return 1
  case "$role" in DeveloperRead|DeveloperWrite|DeveloperManage|ResourceOwner)
    [ -n "$rtype" ] || read -r -p "資源類型(Topic | Group): " rtype; [ -n "$rname" ] || read -r -p "名稱 prefix(例 orders.): " rname
    v_rtype "$rtype" || return 1; v_prefix "$rname" || return 1;;
  esac
  local m; [ "$op" = add ] && m=POST || m=DELETE
  core_confirm "$op  Group:$g  $role ${rtype:+$rtype:$rname*}(ticket $OP_TICKET)" || return 1
  if [ -n "$rtype" ]; then be_mds "$m" "/security/1.0/principals/Group:$g/roles/$role/bindings" "$(_bind_body "$rtype" "$rname" PREFIXED)" | _http_ok
  else be_mds "$m" "/security/1.0/principals/Group:$g/roles/$role" "$(_scope)" | _http_ok; fi || { echo "MDS 回應失敗"; return 1; }
  echo "已完成:$op Group:$g $role"
}

reg 43 4 y n "匯出 audit 紀錄" "匯出最近 N 分鐘的紀錄到檔案,交給 auditor(需 audit topic 與 ${OPMENU_AUDIT_GROUP_PREFIX}* consumer group 的 DeveloperRead)"
_audit_fetch() { # _audit_fetch <分鐘> <輸出檔>:讀 audit topic,用事件時間留下最近 N 分鐘的事件
  local mins="$1" f="$2" since; since=$(( ($(date +%s) - mins*60) * 1000 ))
  # 讀整個 topic,用事件時間過濾出最近 N 分鐘(audit 事件的 time 欄為 ISO8601);--from-beginning 取的是最舊的,所以不能用 --max-messages 當「最近」
  be_kafka kafka-console-consumer --topic "$OPMENU_AUDIT_TOPIC" --from-beginning --timeout-ms 15000 --group "${OPMENU_AUDIT_GROUP_PREFIX}$OP_USER-$$-$RANDOM" --consumer-property enable.auto.commit=false 2>/dev/null \
    | awk -v s="$since" '{ if (match($0, /"time":"[0-9T:.-]+Z?"/)) { t=substr($0, RSTART+8, RLENGTH-9); gsub(/[-:TZ]/, " ", t); split(t, a, " "); ts=mktime(a[1]" "a[2]" "a[3]" "a[4]" "a[5]" "int(a[6]), 1)*1000; if (ts >= s) print } }' > "$f" || true
}
act_43() {
  local mins="${1:-60}"; v_number "$mins" "分鐘" || return 1
  local f="$OPMENU_OUT_DIR/audit-$(date +%Y%m%d-%H%M%S)-$OP_USER.jsonl"
  _audit_fetch "$mins" "$f"
  local c; c=$(grep -c '"type"' "$f"); [ "$c" -gt 0 ] || { echo "最近 $mins 分鐘沒有讀到紀錄(或沒有權限)"; return 1; }
  echo "已匯出最近 $mins 分鐘共 $c 筆:$f"
}

reg 44 4 n n "匯出權限清單(permission review)" "列出各 role 的所有 principal 與資源範圍(CSV),交給定期權限覆核;需 SecurityAdmin 或 UserAdmin"
act_44() {
  local f="$OPMENU_OUT_DIR/permission-review-$(date +%Y%m%d-%H%M%S)-$OP_USER.csv" role p res code body rb arr o n=0 rt rn pt
  echo "role,principal,resource_type,resource_name,pattern_type" > "$f"
  for role in $OPMENU_REVIEW_ROLES; do
    v_match "$role" '^[A-Za-z]+$' "role 名稱" >/dev/null || continue
    res=$(be_mds POST "/security/1.0/lookup/role/$role" "$(_scope)"); code="${res##*HTTP }"; body="${res%$'\n'HTTP*}"
    [ "$code" = 200 ] || { echo "查詢 role $role 失敗(HTTP $code);需要 SecurityAdmin 或 UserAdmin"; rm -f "$f"; return 1; }
    for p in $(printf '%s' "$body" | grep -o '"[A-Za-z]*:[^"]*"' | tr -d '"'); do
      v_principal "$p" >/dev/null || continue
      rb=$(be_mds POST "/security/1.0/lookup/rolebindings/principal/$p" "$(_scope)" | sed '$d')
      arr=$(printf '%s' "$rb" | sed -n 's/.*"'"$role"'":\[\([^]]*\)\].*/\1/p')
      if [ -z "$arr" ]; then printf '"%s","%s","Cluster","",""\n' "$role" "$p" >> "$f"; n=$((n+1))
      else
        while IFS= read -r o; do
          rt=$(printf '%s' "$o" | grep -o '"resourceType":"[^"]*"' | cut -d'"' -f4); rn=$(printf '%s' "$o" | grep -o '"name":"[^"]*"' | cut -d'"' -f4); pt=$(printf '%s' "$o" | grep -o '"patternType":"[^"]*"' | cut -d'"' -f4)
          printf '"%s","%s","%s","%s","%s"\n' "$role" "$p" "$rt" "$rn" "$pt" >> "$f"; n=$((n+1))
        done < <(printf '%s' "$arr" | sed 's/},{/}\n{/g')
      fi
    done
  done
  echo "已匯出 $n 筆權限:$f"
}

reg 45 4 y n "查詢 audit 紀錄(依主體、結果篩選)" "最近 N 分鐘的 audit 事件,可依主體(例 gary)與結果(DENIED 或 ALLOWED)篩選,畫面顯示最後 50 筆;需要 audit topic 的 DeveloperRead(同 43)"
act_45() {
  local mins="${1:-60}" who="${2:-}" res="${3:-}"; v_number "$mins" "分鐘" || return 1
  if [ -n "$who" ]; then [[ "$who" == *:* ]] || who="User:$who"; v_principal "$who" || return 1; fi
  [ -z "$res" ] || v_in "$res" "DENIED ALLOWED" "結果" || return 1
  local f sel; f="$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")"; sel="$f.sel"
  _audit_fetch "$mins" "$f"
  [ -s "$f" ] || { rm -f "$f"; echo "最近 $mins 分鐘沒有讀到紀錄(或沒有權限)"; return 1; }
  if [ -n "$who" ]; then grep -iF "\"principal\":\"$who\"" "$f" > "$sel" || true; else cp "$f" "$sel"; fi
  case "$res" in DENIED) grep -F '"granted":false' "$sel" > "$f" || true;; ALLOWED) grep -F '"granted":true' "$sel" > "$f" || true;; *) cp "$sel" "$f";; esac
  echo "最近 $mins 分鐘符合 $(wc -l < "$f") 筆${who:+(主體 $who)}${res:+(結果 $res)};顯示最後 50 筆:"
  local line t pr m op rn g
  tail -50 "$f" | while IFS= read -r line; do
    t=$(printf '%s' "$line" | grep -o '"time":"[^"]*"' | head -1 | cut -d'"' -f4); pr=$(printf '%s' "$line" | grep -o '"principal":"[^"]*"' | head -1 | cut -d'"' -f4)
    m=$(printf '%s' "$line" | grep -o '"methodName":"[^"]*"' | head -1 | cut -d'"' -f4); op=$(printf '%s' "$line" | grep -o '"operation":"[^"]*"' | head -1 | cut -d'"' -f4)
    rn=$(printf '%s' "$line" | grep -o '"resourceName":"[^"]*"' | tail -1 | cut -d'"' -f4); g=$(printf '%s' "$line" | grep -o '"granted":[a-z]*' | head -1 | cut -d: -f2)
    printf '%s %-16s %-20s %-14s %-26s %s\n' "${t%%.*}" "$pr" "$m" "$op" "$rn" "$([ "$g" = true ] && echo ALLOWED || echo DENIED)"
  done
  rm -f "$f" "$sel"
}

reg 91 4 y y "緊急模式(bootstrap 身分執行一個指令)" "只在一般權限無法處理時使用;工具與動作限於 OPMENU_EMERGENCY_ACTIONS;必填原因;逐條記錄;事後必須檢討"
_emergency_ok() { # _emergency_ok <工具> <參數...>:工具要在清單內;參數中屬於「動作」的選項都要在該工具允許的動作內;不得覆寫連線設定
  local tool="$1"; shift; v_tool "$tool" || return 1
  local allowed="" e; for e in $OPMENU_EMERGENCY_ACTIONS; do [ "${e%%=*}" = "$tool" ] && allowed="${e#*=}"; done
  [ -n "$allowed" ] || { echo "緊急模式沒有為 $tool 定義允許的動作(OPMENU_EMERGENCY_ACTIONS)"; return 1; }
  local a found=0; for a in "$@"; do
    case "$a" in --bootstrap-server|--command-config|--bootstrap-controller) echo "緊急模式不允許覆寫連線設定($a)"; return 1;; esac
    case "$a" in --list|--describe|--create|--alter|--delete|--add|--remove|--reset-offsets|--execute|--generate|--verify|describe|add|remove) found=1; v_in "$a" "${allowed//,/ }" "$tool 的動作" || return 1;; esac
  done
  [ $found = 1 ] || { echo "緊急模式的參數必須包含一個動作(例如 --list、--describe)"; return 1; }
}
act_91() {
  local tool="${1:-}"; [ -n "$tool" ] || read -r -p "要執行的 Kafka 工具(例 kafka-topics): " tool
  local args=("${@:2}"); if [ ${#args[@]} = 0 ]; then read -r -p "參數: " -a args; fi
  _emergency_ok "$tool" "${args[@]}" || return 1
  local reason="${OPMENU_REASON:-}"; [ -n "$reason" ] || read -r -p "原因(必填,會記錄): " reason
  [ -n "$reason" ] || { echo "緊急模式必須填原因"; return 1; }
  core_confirm "以 bootstrap(super user)執行:$tool ${args[*]}(ticket $OP_TICKET;原因:$reason)" || return 1
  core_log EMERGENCY "91 bootstrap" "$tool ${args[*]} | 原因=$reason"
  be_bootstrap_kafka "$tool" "${args[@]}"
}
