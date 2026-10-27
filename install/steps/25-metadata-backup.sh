#!/usr/bin/env bash
# 第 25 站：日常備份 —— 叢集中繼資料每天匯出（RBAC、ACL、topic 與設定、SCRAM 帳號清單與配額、features、broker 動態設定）（手把手第 25 章）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；裝好之後跑 grant、schedule 各一次，之後由 timer 每天跑 run）
#
# 用法：
#   bash steps/25-metadata-backup.sh grant      svc-backup 的最小權限：RBAC SecurityAdmin＋ACL（Topic * 與 Cluster 的 Describe、DescribeConfigs）
#                                               並產生 client-backup.properties；svc-backup 憑證要先有（conf/certs.txt，第 9 站或手把手 25.1）
#   bash steps/25-metadata-backup.sh run        匯出一次到 ~/backup/metadata/<時間>/（變更前手動跑一次當快照）
#   bash steps/25-metadata-backup.sh schedule   操作機的 systemd timer：每天 02:00 跑 run（以 root 身分）
#   bash steps/25-metadata-backup.sh compare    比對最近兩次的備份，哪些檔有變
#
# 各台的 /etc/confluent 由銀行的主機備份系統備；私鑰、密碼、master key 在事件發生時交 CyberArk，不在這支。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-run}
KEEP_DAYS=${KEEP_DAYS:-30}
BACKUP_ROOT=${BACKUP_ROOT:-$HOME/backup/metadata}
BACKUP_CLIENT_CONF=$CONF_DIR/client-backup.properties
TIMER_NAME=confluent-metadata-backup
MDS_URL=https://$(fqdn "${BROKERS%% *}"):8090

cluster_id() { curl -s "$MDS_URL/v1/metadata/id" | grep -o '"id":"[^"]*"' | cut -d'"' -f4; }
# cli_as <憑證名稱> <confluent 子命令…>：confluent CLI 用自己的 HOME，免得蓋掉操作機原本的登入身分
cli_as() {
  local cert_name=$1; shift
  local cli_home=$BACKUP_ROOT/.cli-$cert_name
  install -d -m 0700 "$cli_home"
  HOME=$cli_home confluent login --url "$MDS_URL" --certificate-authority-path "$CERTS_DIR/bank-root.pem" --certificate-only \
    --client-cert-path "$CERTS_DIR/$cert_name.crt" --client-key-path "$KEYS_DIR/$cert_name.key" >/dev/null 2>&1 || return 1
  HOME=$cli_home confluent "$@"
}

grant() {
  local admin=(--bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF")
  section "25.1 svc-backup 憑證與 client 設定"
  [ -s "$CERTS_DIR/svc-backup.p12" ] || die "沒有 $CERTS_DIR/svc-backup.p12：conf/certs.txt 要有 svc-backup，重跑第 9 站（或照手把手 25.1）"
  (umask 077; sed "s#/svc-ops.p12#/svc-backup.p12#" "$ADMIN_CLIENT_CONF" > "$BACKUP_CLIENT_CONF")
  grep -q svc-backup.p12 "$BACKUP_CLIENT_CONF" && ok "client-backup.properties 指向 svc-backup.p12" || die "client-backup.properties 產生失敗"
  section "25.2 最小權限：SecurityAdmin＋兩條 ACL"
  if retry 3 5 cli_as svc-ops iam rbac role-binding create --principal User:svc-backup --role SecurityAdmin --kafka-cluster "$(cluster_id)" >/dev/null; then ok "SecurityAdmin"
  else fail "SecurityAdmin role binding"; fi
  kafka-acls "${admin[@]}" --add --allow-principal User:svc-backup --operation Describe --operation DescribeConfigs --topic '*' >/dev/null 2>&1 &&
    kafka-acls "${admin[@]}" --add --allow-principal User:svc-backup --operation Describe --operation DescribeConfigs --cluster >/dev/null 2>&1 &&
    ok "ACL：$(kafka-acls "${admin[@]}" --list --principal User:svc-backup 2>/dev/null | grep -c 'operation=') 條" || fail "ACL"
  section "25.2 反向：讀不到訊息、建不了 topic、改不了 role binding"
  grep -q AuthorizationException <<<"$(kafka-console-consumer --bootstrap-server "$BROKER_TOKEN" --consumer.config "$BACKUP_CLIENT_CONF" --topic "$(grep -v '^#' "$INSTALL_DIR/conf/topics.txt" | awk 'NF{print $1; exit}')" --from-beginning --max-messages 1 --timeout-ms 10000 2>&1)" && ok "讀訊息被拒" || fail "svc-backup 讀得到訊息"
  grep -q AuthorizationException <<<"$(kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$BACKUP_CLIENT_CONF" --create --topic backup-sneak --partitions 1 --replication-factor 3 2>&1)" && ok "建 topic 被拒" || fail "svc-backup 建得了 topic"
  grep -q 403 <<<"$(cli_as svc-backup iam rbac role-binding create --principal User:svc-backup --role SystemAdmin --kafka-cluster "$(cluster_id)" 2>&1)" && ok "改 role binding 被拒（403）" || fail "svc-backup 改得了 role binding"
}

run_backup() {
  local out failed="" file
  local backup=(--bootstrap-server "$BROKER_TOKEN" --command-config "$BACKUP_CLIENT_CONF")
  [ -s "$BACKUP_CLIENT_CONF" ] || die "沒有 $BACKUP_CLIENT_CONF：先跑 bash $0 grant"
  out=$BACKUP_ROOT/$(date +%Y%m%d-%H%M); install -d -m 0700 "$out"
  section "25.3 匯出到 $out"
  # save <檔名> <指令…>：輸出存檔；失敗或空的就記下來，錯誤訊息留在 <檔名>.err
  save() { file=$1; shift; if "$@" > "$out/$file" 2> "$out/$file.err" && [ -s "$out/$file" ]; then rm -f "$out/$file.err"; else failed="$failed $file"; fi; }
  # 比對兩天的備份靠 sha256：features 的 Epoch 每次不同、ACL 與帳號清單的順序不固定，所以拿掉與排序
  features() { kafka-features "${backup[@]}" describe | sed 's/[[:space:]]*Epoch: [0-9]*//'; }
  acls() { kafka-acls "${backup[@]}" --list | grep . | sort; }
  scram_and_quotas() { kafka-configs "${backup[@]}" --describe --entity-type users | sort; }
  rbac() {
    local role principal cid; cid=$(cluster_id)
    for principal in $(for role in $(cli_as svc-backup iam rbac role list -o json | grep -o '"name": *"[A-Za-z]*"' | cut -d'"' -f4); do
                         cli_as svc-backup iam rbac role-binding list --role "$role" --kafka-cluster "$cid" -o json 2>/dev/null; done |
                       grep -o '"principal": *"[^"]*"' | cut -d'"' -f4 | sort -u); do
      echo "== $principal"; cli_as svc-backup iam rbac role-binding list --principal "$principal" --kafka-cluster "$cid" | tail -n +3
    done
  }
  save topics.txt         kafka-topics "${backup[@]}" --describe
  save topic-configs.txt  kafka-configs "${backup[@]}" --describe --entity-type topics
  save users.txt          scram_and_quotas
  save broker-configs.txt kafka-configs "${backup[@]}" --describe --entity-type brokers --entity-default
  save features.txt       features
  save acls.txt           acls
  save rbac.txt           rbac
  (cd "$out" && sha256sum -- *.txt > SHA256SUMS)
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +"$KEEP_DAYS" -exec rm -rf {} +
  for file in "$out"/*.txt; do log "$(printf '%-18s %4s 行' "$(basename "$file")" "$(wc -l < "$file")")"; done
  if [ -n "$failed" ]; then logger -t confluent-backup -p user.err "中繼資料匯出有失敗：$failed（$out）"; fail "匯出失敗：$failed"
  else logger -t confluent-backup -p user.info "中繼資料已匯出：$out"; ok "已匯出（RBAC $(grep -c '^== ' "$out/rbac.txt") 個 principal）"; fi
}

schedule() {
  section "25.4 每天 02:00 匯出（systemd timer：$TIMER_NAME）"
  printf '[Unit]\nDescription=Confluent cluster metadata export\n\n[Service]\nType=oneshot\nUser=%s\nExecStart=/bin/bash %s run\n' \
    "$(id -un)" "$INSTALL_DIR/steps/25-metadata-backup.sh" | tee "/etc/systemd/system/$TIMER_NAME.service" >/dev/null
  printf '[Unit]\nDescription=Daily Confluent cluster metadata export\n\n[Timer]\nOnCalendar=*-*-* 02:00:00\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' |
    tee "/etc/systemd/system/$TIMER_NAME.timer" >/dev/null
  systemctl daemon-reload
  systemctl enable --now "$TIMER_NAME.timer" >/dev/null 2>&1 || die "timer 啟用失敗"
  systemctl start "$TIMER_NAME.service" || fail "第一次匯出失敗（看 journalctl -u $TIMER_NAME）"
  ok "下次執行：$(systemctl show "$TIMER_NAME.timer" -p NextElapseUSecRealtime --value)"
  ok "syslog：$(journalctl -t confluent-backup -n 1 --no-pager -o cat)"
}

compare() {
  local older newer
  read -r older newer <<<"$(cd "$BACKUP_ROOT" && ls -d 20* 2>/dev/null | tail -2 | paste -sd' ')"
  [ -n "${newer:-}" ] || die "$BACKUP_ROOT 裡不到兩次備份"
  section "25.5 比對 $older → $newer"
  join -1 2 -2 2 <(sort -k2 "$BACKUP_ROOT/$older/SHA256SUMS") <(sort -k2 "$BACKUP_ROOT/$newer/SHA256SUMS") |
    awk '{printf "%-18s %s\n", $1, ($2 == $3 ? "相同" : "有變")}' | while read -r line; do log "$line"; done
}

case $ACTION in
  grant)    grant; finish_step;;
  run)      run_backup; [ "$FAIL_COUNT" = 0 ];;
  schedule) schedule; finish_step;;
  compare)  compare;;
  *) die "用法：bash $0 grant|run|schedule|compare";;
esac
