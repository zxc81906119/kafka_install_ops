# 第三層:變更作業(需 ticket;能不能做由 Kafka 的 RBAC 依操作者本人的群組決定)
# 命名規範、replication factor、受保護 topic 等都在 opmenu.conf / lib/defaults.sh;所有輸入先過 lib/validate.sh

_scope() { printf '{"clusters":{"kafka-cluster":"%s"}}' "$OPMENU_KAFKA_CLUSTER_ID"; }
_bind_body() { printf '{"scope":%s,"resourcePatterns":[{"resourceType":"%s","name":"%s","patternType":"%s"}]}' "$(_scope)" "$1" "$2" "$3"; }
_http_ok() { tail -1 | grep -q -E "HTTP 2[0-9][0-9]"; }
_gen_pw() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }
# 停用帳號 = 把 SCRAM 憑證覆寫成隨機密碼,不用 --delete-config:實測刪除 SCRAM 憑證後,下一次重啟 broker 會失敗(RUNBOOK 第 19 章)。帳號本來就沒有憑證時不動作。
_disable_scram() { local a="$1"; be_kafka kafka-configs --describe --entity-type users --entity-name "$a" 2>/dev/null | grep -q "SCRAM-SHA-512=" || { echo "帳號 $a 沒有 SCRAM 憑證,略過"; return 0; }; be_kafka kafka-configs --alter --add-config "SCRAM-SHA-512=[password=$(_gen_pw)]" --entity-type users --entity-name "$a"; }
_unbind_user() { be_mds DELETE "/security/1.0/principals/User:$1/roles/$2/bindings" "$(_bind_body "$3" "$4" PREFIXED)" >/dev/null 2>&1; }

reg 31 3 y y "建立 topic" "名稱須符合命名規範 <系統>.<名稱>;replication factor 固定為標準值"
act_31() {
  local t="${1:-}" p="${2:-}"; [ -n "$t" ] || read -r -p "topic 名稱: " t; [ -n "$p" ] || read -r -p "partition count: " p
  v_topic "$t" || return 1; v_number "$p" "partition count" || return 1
  core_confirm "建立 topic $t(partition $p、replica $OPMENU_REPLICATION;ticket $OP_TICKET)" || return 1
  be_kafka kafka-topics --create --topic "$t" --partitions "$p" --replication-factor "$OPMENU_REPLICATION"
}

reg 32 3 y y "修改 topic retention" "顯示改前改後的值;受保護的 topic 不處理"
act_32() {
  local t="${1:-}" ms="${2:-}"; [ -n "$t" ] || read -r -p "topic 名稱: " t; [ -n "$ms" ] || read -r -p "新的 retention(毫秒): " ms
  v_topic "$t" || return 1; v_number "$ms" "retention" || return 1
  local cur; cur=$(be_kafka kafka-configs --describe --entity-type topics --entity-name "$t" --all 2>/dev/null | grep -o 'retention.ms=[0-9-]*' | head -1)
  core_confirm "修改 $t 的 retention:${cur:-未知} → retention.ms=$ms(ticket $OP_TICKET)" || return 1
  be_kafka kafka-configs --alter --entity-type topics --entity-name "$t" --add-config "retention.ms=$ms"
}

reg 33 3 y y "刪除 topic" "有 consumer 在線時拒絕;受保護的 topic 不處理"
act_33() {
  local t="${1:-}"; [ -n "$t" ] || read -r -p "要刪除的 topic: " t
  v_topic "$t" || return 1
  # 一次描述全部 group,找出成員正在訂閱這個 topic 的 group(精確比對 topic 欄,不用子字串)
  local active; active=$(be_kafka kafka-consumer-groups --describe --all-groups --members --verbose 2>/dev/null | awk -v t="$t" '$1 !~ /^(GROUP|$)/ { for (i=1;i<=NF;i++) if ($i == t || $i ~ "^" t "\\(") { print $1; break } }' | sort -u)
  [ -z "$active" ] || { echo "有 consumer 正在讀這個 topic:$(echo "$active" | tr '\n' ' ');拒絕刪除"; return 1; }
  core_confirm "刪除 topic $t,資料不可復原(ticket $OP_TICKET)" || return 1
  be_kafka kafka-topics --delete --topic "$t"
}

reg 34 3 y y "新增 service account" "建 SCRAM 帳號並 bind 該系統 topic prefix 的讀寫權限;密碼由系統產生,只顯示一次;binding 失敗會回滾(建帳號需 ClusterAdmin;綁權限需 UserAdmin)"
act_34() {
  local a="${1:-}" prefix="${2:-}" mode="${3:-rw}"; [ -n "$a" ] || read -r -p "帳號(svc-<系統>): " a; [ -n "$prefix" ] || read -r -p "topic prefix(例 orders.): " prefix
  v_svc_acct "$a" || return 1; v_prefix "$prefix" || return 1; v_in "$mode" "rw ro" "模式" || return 1
  core_confirm "建立帳號 $a,授權 $prefix* 的讀寫(ticket $OP_TICKET)" || return 1
  local pw; pw=$(_gen_pw)
  be_kafka kafka-configs --alter --add-config "SCRAM-SHA-512=[password=$pw]" --entity-type users --entity-name "$a" || return $?
  local r ok=1; for r in DeveloperRead DeveloperWrite; do
    [ "$mode" = ro ] && [ "$r" = DeveloperWrite ] && continue
    be_mds POST "/security/1.0/principals/User:$a/roles/$r/bindings" "$(_bind_body Topic "$prefix" PREFIXED)" | _http_ok || { echo "binding $r 失敗"; ok=0; break; }
  done
  [ $ok = 1 ] && { be_mds POST "/security/1.0/principals/User:$a/roles/DeveloperRead/bindings" "$(_bind_body Group "$prefix" PREFIXED)" | _http_ok || { echo "binding consumer group 失敗"; ok=0; }; }
  if [ $ok = 0 ]; then   # 回滾:解除已綁的、刪掉帳號,不留下沒人管的帳號
    for r in DeveloperRead DeveloperWrite; do _unbind_user "$a" "$r" Topic "$prefix"; done; _unbind_user "$a" DeveloperRead Group "$prefix"
    _disable_scram "$a" >/dev/null 2>&1
    echo "已回滾:帳號 $a 與 binding 都已移除"; return 1
  fi
  echo "帳號 $a 已建立;密碼(只顯示這一次,請存入密碼庫):$pw"
}

reg 35 3 y y "更換 service account 密碼" "同帳號改密碼;舊密碼對新連線立即失效,application 要同步更換(需 ClusterAdmin)"
act_35() {
  local a="${1:-}"; [ -n "$a" ] || read -r -p "帳號: " a
  v_svc_acct "$a" || return 1
  core_confirm "更換 $a 的密碼;application 必須立刻換成新密碼(ticket $OP_TICKET)" || return 1
  local pw; pw=$(_gen_pw)
  be_kafka kafka-configs --alter --add-config "SCRAM-SHA-512=[password=$pw]" --entity-type users --entity-name "$a" || return $?
  echo "新密碼(只顯示這一次,請存入密碼庫):$pw"
}

reg 36 3 y y "重設 consumer 讀取位置" "該 consumer group 必須先停止;可重設到最早、最新或指定時間"
act_36() {
  local g="${1:-}" to="${2:-}"; [ -n "$g" ] || read -r -p "consumer group: " g; [ -n "$to" ] || read -r -p "重設到(earliest | latest | 2026-01-31T00:00:00.000): " to
  v_group "$g" || return 1; v_offset_to "$to" || return 1
  local opt; case "$to" in earliest) opt="--to-earliest";; latest) opt="--to-latest";; *) opt="--to-datetime $to";; esac
  if be_kafka kafka-consumer-groups --describe --group "$g" --members 2>/dev/null | grep -q -E '^[^ ]+ +[^ ]+ +/'; then echo "consumer group $g 仍有成員在線,拒絕重設(先停止 application)"; return 1; fi
  echo "-- 預覽(不會執行):"; be_kafka kafka-consumer-groups --reset-offsets --group "$g" --all-topics $opt --dry-run || return $?
  core_confirm "重設 $g 的讀取位置到 $to(ticket $OP_TICKET)" || return 1
  be_kafka kafka-consumer-groups --reset-offsets --group "$g" --all-topics $opt --execute
}

reg 37 3 y y "下架 service account" "34 的反向:解除該帳號的 binding 並停用 SCRAM 帳號(憑證覆寫成隨機密碼,不刪除;需 ClusterAdmin 與 UserAdmin)"
act_37() {
  local a="${1:-}" prefix="${2:-}"; [ -n "$a" ] || read -r -p "帳號(svc-<系統>): " a; [ -n "$prefix" ] || read -r -p "topic prefix(例 orders.): " prefix
  v_svc_acct "$a" || return 1; v_prefix "$prefix" || return 1
  echo "-- 目前的 binding:"; be_mds POST "/security/1.0/lookup/rolebindings/principal/User:$a" "$(_scope)" | sed '$d'
  core_confirm "解除 $a 對 $prefix* 的 binding 並刪除帳號;使用這個帳號的 application 會立刻無法連線(ticket $OP_TICKET)" || return 1
  local r; for r in DeveloperRead DeveloperWrite; do _unbind_user "$a" "$r" Topic "$prefix"; done; _unbind_user "$a" DeveloperRead Group "$prefix"
  _disable_scram "$a" && echo "帳號 $a 已下架"
}
