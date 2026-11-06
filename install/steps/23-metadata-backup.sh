#!/usr/bin/env bash
# 第 23 站：日常備份 —— 叢集中繼資料每天匯出（RBAC、ACL、topic 與設定、SCRAM 帳號清單與配額、features、broker 動態設定）（手把手第 23 章）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；裝好之後跑 grant、schedule 各一次，之後由 timer 每天跑 run）
#
# 做什麼：
#   bash steps/23-metadata-backup.sh grant      svc-backup 的最小權限：RBAC SecurityAdmin＋ACL（Topic * 與 Cluster 的 Describe、DescribeConfigs）
#                                               並產生 client-backup.properties；svc-backup 憑證要先有（conf/certs.txt，第 9 站或手把手 23.1）
#   bash steps/23-metadata-backup.sh run        匯出一次到 ~/backup/metadata/<時間>/（變更前手動跑一次當快照）
#   bash steps/23-metadata-backup.sh schedule   操作機的 systemd timer：每天 02:00 跑 run（以 root 身分）
#   bash steps/23-metadata-backup.sh compare    比對最近兩次的備份，哪些檔有變
#   bash steps/23-metadata-backup.sh restore <備份目錄> <topic|-> <帳號|->   23.6 從備份重建一個 topic、一個 principal 的 binding、一個 SCRAM 帳號（密碼讀 ~/secrets/<帳號>.pass）
#   bash steps/23-metadata-backup.sh restore-all <備份目錄>   26.4 叢集重置後全部建回來（應用程式 topic、全部 binding、SCRAM、配額、ACL、broker 動態設定）
#   bash steps/23-metadata-backup.sh drill      23.6 還原演練：建演練物件 → 備份 → 誤刪 → restore → 寫讀一筆 → 清掉
#
# 需要什麼：第 11 站之後的叢集；svc-backup、svc-ops 的憑證（~/pki）；還原時 ~/secrets/<帳號>.pass（0600，密碼不在備份裡）。
# 產出什麼：~/backup/metadata/<時間>/ 的文字檔與 SHA256SUMS，保留 KEEP_DAYS（預設 30）天；syslog tag confluent-backup。
#   各台的 /etc/confluent 由銀行的主機備份系統備；~/pki 的私鑰、~/secrets、master key 由銀行的備份機制備份操作機（要加密），不在這支；/secure/ssh 的私鑰不備份。
# 能不能重跑：grant、run、schedule、compare 可以；同一分鐘再 run 會蓋掉前一份。restore 的 topic 已存在時會失敗（--create）。
#
# 改的時候要注意：備份檔的內容要和 OP menu 44 的快照逐位元組相同（23.5 用 sha256 互相比對；opmenu/items/44-permission-review.sh）：
#   features_list、acl_lines、users_list、principals_with_bindings、bindings_of 裡的 sed／awk／sort 不能改；26.4 也照這個格式讀回來。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-run}
KEEP_DAYS=${KEEP_DAYS:-30}
BACKUP_ROOT=${BACKUP_ROOT:-$HOME/backup/metadata}
BACKUP_CLIENT_CONF=$CONF_DIR/client-backup.properties
TIMER_NAME=confluent-metadata-backup
MDS_URL=https://$(fqdn "${BROKERS%% *}"):8090

# 管理用與備份用的連線參數
ADMIN_ARGS=(--bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF")
BACKUP_ARGS=(--bootstrap-server "$BROKER_TOKEN" --command-config "$BACKUP_CLIENT_CONF")

# cluster_id：MDS 回報的 cluster id，例：{"id":"AbC…","scope":…} → AbC…
cluster_id() {
  curl -s "$MDS_URL/v1/metadata/id" | grep -o '"id":"[^"]*"' | cut -d'"' -f4
}

# cli_as <憑證名稱> <confluent 子命令…>：confluent CLI 用自己的 HOME，免得蓋掉操作機原本的登入身分
cli_as() {
  local cert_name=$1
  shift
  local cli_home=$BACKUP_ROOT/.cli-$cert_name

  install -d -m 0700 "$cli_home"

  if ! HOME=$cli_home confluent login --url "$MDS_URL" \
    --certificate-authority-path "$CERTS_DIR/bank-root.pem" --certificate-only \
    --client-cert-path "$CERTS_DIR/$cert_name.crt" --client-key-path "$KEYS_DIR/$cert_name.key" >/dev/null 2>&1; then
    return 1
  fi

  HOME=$cli_home confluent "$@"
}

grant() {
  local cluster first_topic reply acl_count first_line

  # 1. client 設定：管理用的那份複製一份，keystore 換成 svc-backup 的（檔案 0600）
  section "23.1 svc-backup 憑證與 client 設定"

  if [ ! -s "$CERTS_DIR/svc-backup.p12" ]; then
    die "沒有 $CERTS_DIR/svc-backup.p12：conf/certs.txt 要有 svc-backup，重跑第 9 站（或照手把手 23.1）"
  fi

  install -m 0600 /dev/null "$BACKUP_CLIENT_CONF"
  sed "s#/svc-ops.p12#/svc-backup.p12#" "$ADMIN_CLIENT_CONF" > "$BACKUP_CLIENT_CONF"

  if grep -q svc-backup.p12 "$BACKUP_CLIENT_CONF"; then
    ok "client-backup.properties 指向 svc-backup.p12"
  else
    die "client-backup.properties 產生失敗"
  fi

  # 2. SecurityAdmin：只能看 role binding
  section "23.2 最小權限：SecurityAdmin＋兩條 ACL"
  cluster=$(cluster_id)

  if mds_write cli_as svc-ops iam rbac role-binding create \
       --principal User:svc-backup --role SecurityAdmin --kafka-cluster "$cluster" >/dev/null; then
    ok "SecurityAdmin"
  else
    fail "SecurityAdmin role binding"
  fi

  # 3. 兩條 ACL：所有 topic、cluster 本身的 Describe 與 DescribeConfigs
  if ! kafka-acls "${ADMIN_ARGS[@]}" --add --allow-principal User:svc-backup \
       --operation Describe --operation DescribeConfigs --topic '*' >/dev/null 2>&1; then
    fail "ACL"
  elif ! kafka-acls "${ADMIN_ARGS[@]}" --add --allow-principal User:svc-backup \
       --operation Describe --operation DescribeConfigs --cluster >/dev/null 2>&1; then
    fail "ACL"
  else
    acl_count=$(kafka-acls "${ADMIN_ARGS[@]}" --list --principal User:svc-backup 2>/dev/null \
      | awk '/operation=/ {c++} END {print c + 0}')
    ok "ACL：$acl_count 條"
  fi

  # 4. 反向：讀訊息要被拒
  section "23.2 反向：讀不到訊息、建不了 topic、改不了 role binding"
  # topics.txt 第一個不是註解、不是空白的行，取第一欄
  first_line=$(grep -v '^#' "$INSTALL_DIR/conf/topics.txt" | grep '[^[:space:]]' | head -1)
  first_topic=$(awk '{print $1}' <<<"$first_line")
  reply=$(kafka-console-consumer --bootstrap-server "$BROKER_TOKEN" \
    --consumer.config "$BACKUP_CLIENT_CONF" \
    --topic "$first_topic" --from-beginning --max-messages 1 --timeout-ms 10000 2>&1)

  if grep -q AuthorizationException <<<"$reply"; then
    ok "讀訊息被拒"
  else
    fail "svc-backup 讀得到訊息"
  fi

  # 5. 反向：建 topic 要被拒
  reply=$(kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$BACKUP_CLIENT_CONF" \
    --create --topic backup-sneak --partitions 1 --replication-factor 3 2>&1)

  if grep -q AuthorizationException <<<"$reply"; then
    ok "建 topic 被拒"
  else
    fail "svc-backup 建得了 topic"
  fi

  # 6. 反向：改 role binding 要被拒
  reply=$(cli_as svc-backup iam rbac role-binding create \
    --principal User:svc-backup --role SystemAdmin --kafka-cluster "$cluster" 2>&1)

  if grep -q 403 <<<"$reply"; then
    ok "改 role binding 被拒（403）"
  else
    fail "svc-backup 改得了 role binding"
  fi
}

# save <檔名> <指令…>：指令的輸出存成 <檔名>；失敗或是空的就記到 failed，錯誤訊息留在 <檔名>.err
#   out、failed 是 run_backup 的區域變數
save() {
  local file=$1
  shift

  if "$@" > "$out/$file" 2> "$out/$file.err"; then
    if [ -s "$out/$file" ]; then
      rm -f "$out/$file.err"
      return
    fi
  fi

  failed="$failed $file"
}

# 比對兩天的備份靠 sha256：features 的 Epoch 每次不同，ACL、帳號清單、role binding 的順序不固定，所以拿掉與排序（一律 LC_ALL=C；OP menu 44 的快照同格式）

# features_list：features 清單，拿掉每次都不同的 Epoch
#   輸入：Feature: metadata.version  SupportedMinVersion: …  FinalizedVersionLevel: 4.2  Epoch: 123
#   輸出：Feature: metadata.version  SupportedMinVersion: …  FinalizedVersionLevel: 4.2
features_list() {
  kafka-features "${BACKUP_ARGS[@]}" describe | sed 's/[[:space:]]*Epoch: [0-9]*//'
}

# acl_lines：ACL 一條一行「資源類型|名稱|比對方式|principal|host|操作|ALLOW/DENY」，排好順序（和 OP menu 44 的 _item44_acls 同一段 awk）
#   輸入：Current ACLs for resource `ResourcePattern(resourceType=TOPIC, name=*, patternType=LITERAL)`:
#             (principal=User:svc-backup, host=*, operation=DESCRIBE, permissionType=ALLOW)
#   輸出：TOPIC|*|LITERAL|User:svc-backup|*|DESCRIBE|ALLOW
acl_lines() {
  kafka-acls "${BACKUP_ARGS[@]}" --list | acl_text_to_lines | LC_ALL=C sort
}

# acl_text_to_lines：把 kafka-acls --list 的輸出（stdin）轉成一條一行，輸入輸出的例子見 acl_lines
#   遇到資源那一行就記下資源（r），遇到 principal 那一行就印「r|這一條的內容」
acl_text_to_lines() {
  # lint-ok: 要記住上一個資源、改寫多個欄位，grep／cut 做不到；函式上面有輸入輸出例子
  awk '
    /^Current ACLs for resource/ {
      s = $0
      sub(/.*resourceType=/, "", s)
      sub(/\)`:.*/, "", s)
      gsub(/, name=|, patternType=/, "|", s)
      r = s
      next
    }
    /principal=/ {
      s = $0
      sub(/^[ \t]*\(principal=/, "", s)
      sub(/\)[ \t]*$/, "", s)
      # lint-ok: 這行的 | 是 awk 的「或」，不是管線
      gsub(/, host=|, operation=|, permissionType=/, "|", s)
      print r "|" s
    }
  '
}

# users_list：每個帳號的 SCRAM（只有機制與迭代次數，沒有密碼）與配額，排好順序
users_list() {
  kafka-configs "${BACKUP_ARGS[@]}" --describe --entity-type users | LC_ALL=C sort
}

# principals_with_bindings <cluster id>：每個角色的 binding 裡出現過的 principal，排序、去掉重複；一行一個
#   例：User:svc-backup
principals_with_bindings() {
  local cluster=$1
  local roles role bindings_json="" role_json

  # 1. 有哪些角色
  roles=$(cli_as svc-backup iam rbac role list -o json | grep -o '"name": *"[A-Za-z]*"' | cut -d'"' -f4)

  # 2. 每個角色的 binding（JSON）接起來
  for role in $roles; do
    role_json=$(cli_as svc-backup iam rbac role-binding list \
      --role "$role" --kafka-cluster "$cluster" -o json 2>/dev/null)
    bindings_json+="$role_json"$'\n'
  done

  # 3. 取出 principal，排序、去掉重複
  grep -o '"principal": *"[^"]*"' <<<"$bindings_json" | cut -d'"' -f4 | LC_ALL=C sort -u
}

# bindings_of <principal> <cluster id>：這個 principal 的每條 binding 一行，去掉表頭與對齊空白、排好順序
#   輸入：  User:svc-backup | SecurityAdmin | Cluster       |      |
#   輸出：User:svc-backup|SecurityAdmin|Cluster||
bindings_of() {
  cli_as svc-backup iam rbac role-binding list --principal "$1" --kafka-cluster "$2" \
    | binding_table_to_lines \
    | LC_ALL=C sort
}

# binding_table_to_lines：stdin 的 role-binding 表格，去掉兩行表頭與對齊空白（例子見 bindings_of）
binding_table_to_lines() {
  tail -n +3 | sed 's/ *| */|/g; s/^ *//; s/ *$//'
}

# rbac_sections：每個有 binding 的 principal 一段：「== principal」，底下是它的每一條 binding
rbac_sections() {
  local cluster principal

  cluster=$(cluster_id)

  for principal in $(principals_with_bindings "$cluster"); do
    echo "== $principal"
    bindings_of "$principal" "$cluster"
  done
}

run_backup() {
  local out failed="" file file_name line_count principal_count

  if [ ! -s "$BACKUP_CLIENT_CONF" ]; then
    die "沒有 $BACKUP_CLIENT_CONF：先跑 bash $0 grant"
  fi

  # 1. 這次的備份目錄（以分鐘命名）
  out=$BACKUP_ROOT/$(date +%Y%m%d-%H%M)
  install -d -m 0700 "$out"
  section "23.3 匯出到 $out"

  # 2. 七個檔
  save topics.txt         kafka-topics "${BACKUP_ARGS[@]}" --describe
  save topic-configs.txt  kafka-configs "${BACKUP_ARGS[@]}" --describe --entity-type topics
  save users.txt          users_list
  save broker-configs.txt kafka-configs "${BACKUP_ARGS[@]}" --describe --entity-type brokers --entity-default
  save features.txt       features_list
  save acls.txt           acl_lines
  save rbac.txt           rbac_sections

  # 3. 這次每個檔的 sha256（比對兩天的備份就看它）
  (
    if ! cd "$out"; then
      exit 1
    fi

    sha256sum -- *.txt > SHA256SUMS
  )

  # 4. 刪掉超過 KEEP_DAYS 天的舊備份
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +"$KEEP_DAYS" -exec rm -rf {} +

  # 5. 每個檔幾行
  for file in "$out"/*.txt; do
    line_count=$(wc -l < "$file")
    file_name=$(basename "$file")
    log "$(printf '%-18s %4s 行' "$file_name" "$line_count")"
  done

  # 6. 結果寫 syslog
  if [ -n "$failed" ]; then
    logger -t confluent-backup -p user.err "中繼資料匯出有失敗：$failed（$out）"
    fail "匯出失敗：$failed"
  else
    logger -t confluent-backup -p user.info "中繼資料已匯出：$out"
    principal_count=$(awk '/^== / {c++} END {print c + 0}' "$out/rbac.txt")
    ok "已匯出（RBAC $principal_count 個 principal）"
  fi
}

schedule() {
  local service_file=/etc/systemd/system/$TIMER_NAME.service
  local timer_file=/etc/systemd/system/$TIMER_NAME.timer
  local next_run last_syslog

  section "23.4 每天 02:00 匯出（systemd timer：$TIMER_NAME）"

  # 1. service：跑一次匯出
  cat > "$service_file" <<EOF
[Unit]
Description=Confluent cluster metadata export

[Service]
Type=oneshot
User=$(id -un)
ExecStart=/bin/bash $INSTALL_DIR/steps/23-metadata-backup.sh run
EOF

  # 2. timer：每天 02:00（關機錯過的，開機後補跑）
  cat > "$timer_file" <<'EOF'
[Unit]
Description=Daily Confluent cluster metadata export

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # 3. 啟用 timer，並馬上跑一次
  systemctl daemon-reload

  if ! systemctl enable --now "$TIMER_NAME.timer" >/dev/null 2>&1; then
    die "timer 啟用失敗"
  fi

  if ! systemctl start "$TIMER_NAME.service"; then
    fail "第一次匯出失敗（看 journalctl -u $TIMER_NAME）"
  fi

  # 4. 下次什麼時候跑、syslog 最新的一行
  next_run=$(systemctl show "$TIMER_NAME.timer" -p NextElapseUSecRealtime --value)
  last_syslog=$(journalctl -t confluent-backup -n 1 --no-pager -o cat)
  ok "下次執行：$next_run"
  ok "syslog：$last_syslog"
}

# sums_comparison <舊的 SHA256SUMS> <新的 SHA256SUMS>：每個檔一行，sha256 相同還是有變
#   輸入（兩個檔各一行）：aaa…  acls.txt
#   輸出：acls.txt           相同
sums_comparison() {
  local older_sums newer_sums file_name older_sum newer_sum

  older_sums=$(mktemp)
  newer_sums=$(mktemp)
  sort -k2 "$1" > "$older_sums"
  sort -k2 "$2" > "$newer_sums"

  # join 的輸出：檔名 舊的sha256 新的sha256
  join -1 2 -2 2 "$older_sums" "$newer_sums" | while read -r file_name older_sum newer_sum; do
    if [ "$older_sum" = "$newer_sum" ]; then
      printf '%-18s %s\n' "$file_name" "相同"
    else
      printf '%-18s %s\n' "$file_name" "有變"
    fi
  done

  rm -f "$older_sums" "$newer_sums"
}

# new_topics <舊的 topics.txt> <新的 topics.txt>：新的那份多出來的 topic，放在同一行
#   例：Topic: orders.backup-demo
new_topics() {
  local older_topics newer_topics

  older_topics=$(mktemp)
  newer_topics=$(mktemp)
  grep -o 'Topic: [^[:space:]]*' "$1" | sort -u > "$older_topics"
  grep -o 'Topic: [^[:space:]]*' "$2" | sort -u > "$newer_topics"

  grep -vxFf "$older_topics" "$newer_topics" | paste -sd' '

  rm -f "$older_topics" "$newer_topics"
}

compare() {
  local backup_count older newer older_path newer_path line added

  # 1. 最近的兩份
  backup_count=$(ls -d "$BACKUP_ROOT"/20* 2>/dev/null | wc -l)

  if [ "$backup_count" -lt 2 ]; then
    die "$BACKUP_ROOT 裡不到兩次備份"
  fi

  older_path=$(ls -d "$BACKUP_ROOT"/20* | tail -2 | head -1)
  newer_path=$(ls -d "$BACKUP_ROOT"/20* | tail -1)
  older=$(basename "$older_path")
  newer=$(basename "$newer_path")
  section "23.5 比對 $older → $newer"

  # 2. 每個檔：依檔名把兩份 SHA256SUMS 接起來
  while read -r line; do
    log "$line"
  done <<<"$(sums_comparison "$BACKUP_ROOT/$older/SHA256SUMS" "$BACKUP_ROOT/$newer/SHA256SUMS")"

  # 3. describe 的輸出含 leader、ISR，每次都可能「有變」：要看的是多了哪些 topic
  added=$(new_topics "$BACKUP_ROOT/$older/topics.txt" "$BACKUP_ROOT/$newer/topics.txt")

  if [ -z "$added" ]; then
    added=無
  fi

  log "topics.txt 多出來的：$added"
}

# topic_field <備份目錄> <topic> <欄位名稱>：topics.txt 裡這個 topic 第一行的某個欄位
#   輸入：Topic: orders.events	TopicId: …	PartitionCount: 3	ReplicationFactor: 3	Configs: …
#   topic_field 目錄 orders.events PartitionCount → 3
topic_field() {
  local first_line

  first_line=$(grep -P "^Topic: $2\t" "$1/topics.txt" | head -1)
  grep -o "$3: [0-9]*" <<<"$first_line" | tail -1 | cut -d' ' -f2
}

# topic_dynamic_configs <備份目錄> <topic>：topic-configs.txt 裡這個 topic 的動態設定，一行一個 key=value
#   輸入：Dynamic configs for topic orders.events are:
#           retention.ms=3600000 sensitive=false synonyms={…}
#   輸出：retention.ms=3600000
topic_dynamic_configs() {
  # lint-ok: 要找出「某一個 topic 那一段」到下一段之前，grep／cut 做不到；函式上面有輸入輸出例子
  awk -v t="$2" '$0 == "Dynamic configs for topic " t " are:"{p=1;next} /^Dynamic configs/{p=0} p{print $1}' "$1/topic-configs.txt"
}

# binding_args <cluster id> <principal> <角色> <資源類型> <資源名稱> <比對方式>：把 role-binding create 的參數放進陣列 binding_arguments
#   整個 cluster 的不給 --resource；PREFIXED 的多加 --prefix
binding_args() {
  binding_arguments=(--principal "$2" --role "$3" --kafka-cluster "$1")

  if [ -n "$5" ]; then
    binding_arguments+=(--resource "$4:$5")
  fi

  if [ "$6" = PREFIXED ]; then
    binding_arguments+=(--prefix)
  fi
}

# rbac_section_of_user <備份目錄> <帳號>：rbac.txt 裡這個帳號那一段（「== User:<帳號>」到下一個「== 」之前）
#   輸出：User:app-orders-a|DeveloperRead|Topic|orders.|PREFIXED
rbac_section_of_user() {
  # lint-ok: 要找出「某一個帳號那一段」到下一段之前，grep／cut 做不到；函式上面有輸出例子
  awk -v u="User:$2" '$0 == "== " u {p=1;next} /^== /{p=0} p' "$1/rbac.txt"
}

# scram_iterations <備份目錄> <帳號>：users.txt 裡這個帳號的 SCRAM 迭代次數，例：iterations=8192（沒有就印空的）
scram_iterations() {
  grep "SCRAM credential configs for user-principal '$2'" "$1/users.txt" | grep -o 'iterations=[0-9]*' | head -1
}

# set_scram_password <帳號> <iterations=N> <密碼檔>：建 SCRAM 帳號。出錯時 kafka-configs 會印出密碼，所以輸出丟掉
set_scram_password() {
  local password

  password=$(cat "$3")
  kafka-configs "${ADMIN_ARGS[@]}" --alter --entity-type users --entity-name "$1" \
    --add-config "SCRAM-SHA-512=[$2,password=$password]" >/dev/null 2>&1
}

# 23.6 還原：從備份目錄重建 topic（partition 數、RF、動態設定）、一個 principal 的 role binding、SCRAM 帳號（迭代次數、配額）。
#   密碼不在備份裡：讀 $SECRETS_DIR/<帳號>.pass（0600）。topic 或帳號給 - 就跳過那一項。
#   set -f：rbac.txt 裡有 Topic:* 這種名稱，不能被 shell 換成檔名
restore() {   # restore <備份目錄> <topic|-> <帳號|->
  local dir=$1
  local topic=${2:--}
  local user=${3:--}

  if [ ! -d "$dir" ]; then
    die "沒有備份目錄 $dir"
  fi

  set -f
  section "23.6 從 $dir 還原（topic：$topic、帳號：$user）"

  # 1. topic
  if [ "$topic" != - ]; then
    local partitions replication_factor config_value summary topic_configs
    local config_args=()

    partitions=$(topic_field "$dir" "$topic" PartitionCount)
    replication_factor=$(topic_field "$dir" "$topic" ReplicationFactor)

    if [ -z "$partitions" ]; then
      die "備份裡沒有 topic $topic（$dir/topics.txt）"
    fi

    for config_value in $(topic_dynamic_configs "$dir" "$topic"); do
      config_args+=(--config "$config_value")
    done

    if kafka-topics "${ADMIN_ARGS[@]}" --create --topic "$topic" \
         --partitions "$partitions" --replication-factor "$replication_factor" \
         "${config_args[@]}" >/dev/null 2>&1; then
      ok "topic $topic：partitions=$partitions rf=$replication_factor 動態設定 $(( ${#config_args[@]} / 2 )) 個"
    else
      fail "topic $topic 建不回來"
    fi
  fi

  # 2. 這個帳號的 role binding、SCRAM、配額
  if [ "$user" != - ]; then
    local binding_count=0 principal role resource_type resource_name pattern
    local iterations quota cluster bindings_file binding_arguments

    cluster=$(cluster_id)
    bindings_file=$(mktemp)
    rbac_section_of_user "$dir" "$user" > "$bindings_file"

    while IFS='|' read -r principal role resource_type resource_name pattern; do
      # 去掉每一欄前後的空白（OP menu 44 的快照沒有空白，舊格式的備份有）
      principal=$(echo $principal)
      role=$(echo $role)
      resource_type=$(echo $resource_type)
      resource_name=$(echo $resource_name)
      pattern=$(echo $pattern)

      binding_args "$cluster" "$principal" "$role" "$resource_type" "$resource_name" "$pattern"

      if mds_write cli_as svc-ops iam rbac role-binding create "${binding_arguments[@]}" >/dev/null 2>&1; then
        binding_count=$((binding_count + 1))
      fi
    done < "$bindings_file"

    rm -f "$bindings_file"
    ok "role binding：$binding_count 條"

    iterations=$(scram_iterations "$dir" "$user")
    quota=$(grep "Quota configs for user-principal '$user'" "$dir/users.txt" | sed 's/.* are //; s/\.0\b//g; s/, /,/g')

    if [ ! -s "$SECRETS_DIR/$user.pass" ]; then
      die "沒有 $SECRETS_DIR/$user.pass：密碼不在備份裡，先放密碼檔"
    fi

    if set_scram_password "$user" "${iterations:-iterations=8192}" "$SECRETS_DIR/$user.pass"; then
      ok "SCRAM $user：${iterations:-iterations=8192}"
    else
      fail "SCRAM $user"
    fi

    if [ -n "$quota" ]; then
      if kafka-configs "${ADMIN_ARGS[@]}" --alter --entity-type users --entity-name "$user" \
           --add-config "$quota" >/dev/null 2>&1; then
        ok "配額：$quota"
      else
        fail "配額 $quota"
      fi
    fi
  fi

  # 3. 驗證：還原之後實際看到的樣子
  if [ "$topic" != - ]; then
    local describe_line config_lines

    # describe 第一行：partition 數與 RF
    describe_line=$(kafka-topics "${ADMIN_ARGS[@]}" --describe --topic "$topic" 2>/dev/null | head -1)
    summary=$(grep -o 'PartitionCount: [0-9]*.ReplicationFactor: [0-9]*' <<<"$describe_line" | tr '\t' ' ')

    # 動態設定：key=value 用逗號接起來
    config_lines=$(kafka-configs "${ADMIN_ARGS[@]}" --describe --entity-type topics --entity-name "$topic" 2>/dev/null \
      | grep -o '^  [a-z.]*=[^ ]*')
    topic_configs=$(tr -d ' ' <<<"$config_lines" | paste -sd, -)
    log "describe：$summary；$topic_configs"
  fi

  if [ "$user" != - ]; then
    local bindings_now settings_now

    bindings_now=$(cli_as svc-ops iam rbac role-binding list \
        --principal "User:$user" --kafka-cluster "$cluster" 2>/dev/null \
      | awk -v p="User:$user" 'index($0, p) {c++} END {print c + 0}')
    settings_now=$(kafka-configs "${ADMIN_ARGS[@]}" --describe --entity-type users --entity-name "$user" 2>/dev/null \
      | awk '/./ {c++} END {print c + 0}')
    log "binding：$bindings_now 條；帳號設定：$settings_now 行"
  fi

  set +f
}

# application_topics <備份目錄>：要建回來的 topic（名稱有「.」、不是底線開頭），一行一個
#   輸入：Topic: orders.events	TopicId: …
#   輸出：orders.events
application_topics() {
  grep -oP '^Topic: \K[^\t]+' "$1/topics.txt" | grep '\.' | grep -v '^_'
}

# scram_users <備份目錄>：users.txt 裡有 SCRAM 的帳號，一行一個
#   輸入：SCRAM credential configs for user-principal 'app-orders-a' are SCRAM-SHA-512=iterations=8192
#   輸出：app-orders-a
scram_users() {
  grep -o "SCRAM credential configs for user-principal '[^']*'" "$1/users.txt" | cut -d"'" -f2
}

# quota_lines <備份目錄>：有配額的帳號，一行一個「帳號 key=value,key=value」（kafka-configs --add-config 要的寫法）
#   輸入：Quota configs for user-principal 'app-orders-a' are producer_byte_rate=1048576.0, consumer_byte_rate=2097152.0
#   輸出：app-orders-a producer_byte_rate=1048576,consumer_byte_rate=2097152
quota_lines() {
  # 依序：拿掉開頭到帳號前的引號；帳號後的「' are 」換成一個空白；1048576.0 → 1048576；「, 」→「,」
  grep "^Quota configs for user-principal" "$1/users.txt" \
    | sed "s/^Quota configs for user-principal '//; s/' are / /; s/\.0\b//g; s/, /,/g"
}

# acl_operation_name <DESCRIBE_CONFIGS 這種寫法>：kafka-acls 要的寫法，例：DescribeConfigs
acl_operation_name() {
  local lower_name=${1,,} result="" word
  local -a words

  # 1. 全部小寫後，依底線拆成一個一個字
  IFS='_' read -ra words <<<"$lower_name"

  # 2. 每個字第一個字母大寫，接起來
  for word in "${words[@]}"; do
    result+=${word^}
  done

  printf '%s' "$result"
}

# restore_acls <備份目錄>：acls.txt 一條一行：資源類型|名稱|比對方式|principal|host|操作|ALLOW/DENY
restore_acls() {
  local dir=$1
  local count=0 resource_type name pattern principal host operation permission operation_name
  local resource who

  while IFS='|' read -r resource_type name pattern principal host operation permission; do
    if [ -z "$operation" ]; then
      continue
    fi

    # 資源
    case $resource_type in
      TOPIC)
        resource=(--topic "$name")
        ;;
      GROUP)
        resource=(--group "$name")
        ;;
      CLUSTER)
        resource=(--cluster)
        ;;
      TRANSACTIONAL_ID)
        resource=(--transactional-id "$name")
        ;;
      *)
        fail "不認得的 ACL 資源類型 $resource_type"
        continue
        ;;
    esac

    if [ "$pattern" = PREFIXED ]; then
      resource+=(--resource-pattern-type prefixed)
    fi

    # 操作：備份裡是 DESCRIBE_CONFIGS 這種寫法
    operation_name=$(acl_operation_name "$operation")

    # 誰：ALLOW 或 DENY；host 不是 * 才指定
    if [ "$permission" = DENY ]; then
      who=(--deny-principal "$principal")

      if [ "$host" != '*' ]; then
        who+=(--deny-host "$host")
      fi
    else
      who=(--allow-principal "$principal")

      if [ "$host" != '*' ]; then
        who+=(--allow-host "$host")
      fi
    fi

    if kafka-acls "${ADMIN_ARGS[@]}" --add "${who[@]}" \
         --operation "$operation_name" "${resource[@]}" >/dev/null 2>&1; then
      count=$((count + 1))
    else
      fail "ACL $resource_type:$name $principal $operation"
    fi
  done < "$dir/acls.txt"

  ok "ACL：$count 條"
}

# broker_default_configs <備份目錄>：broker-configs.txt 裡叢集層級的預設值，一行一個 key=value
#   輸入：Default configs for brokers are:
#           log.retention.ms=3600000 sensitive=false synonyms={…}
#   輸出：log.retention.ms=3600000
broker_default_configs() {
  # lint-ok: 要取「標題那一行之後」每行的第一欄，grep／cut 做不到；函式上面有輸入輸出例子
  awk '/^Default configs for brokers/{p=1;next} p{print $1}' "$1/broker-configs.txt"
}

# 26.4 叢集重置之後全部建回來：應用程式 topic（名稱有「.」、不是底線開頭）、全部 role binding、SCRAM 帳號（密碼讀 ~/secrets）、配額、ACL、broker 動態設定。
#   內部 topic、稽核 topic、C3 的 topic 由平台自己重建；訊息內容與 consumer 讀到的位置本來就不在備份裡。
restore_all() {   # restore_all <備份目錄>
  local dir=$1
  local cluster count topic partitions replication_factor config_value
  local config_args

  if [ ! -d "$dir" ]; then
    die "沒有備份目錄 $dir"
  fi

  set -f   # rbac.txt 裡有 Topic:* 這種名稱，不能被 shell 換成檔名
  cluster=$(cluster_id)
  section "26.4 從 $dir 全部建回來（cluster $cluster）"

  # 1. 應用程式 topic
  count=0

  for topic in $(application_topics "$dir"); do
    partitions=$(topic_field "$dir" "$topic" PartitionCount)
    replication_factor=$(topic_field "$dir" "$topic" ReplicationFactor)
    config_args=()

    for config_value in $(topic_dynamic_configs "$dir" "$topic"); do
      config_args+=(--config "$config_value")
    done

    if kafka-topics "${ADMIN_ARGS[@]}" --create --if-not-exists --topic "$topic" \
         --partitions "$partitions" --replication-factor "$replication_factor" \
         "${config_args[@]}" >/dev/null 2>&1; then
      count=$((count + 1))
    else
      fail "topic $topic"
    fi
  done

  ok "topic：$count 個"

  # 2. 全部 role binding：rbac.txt 裡每個 principal 的每一行
  local principal role resource_type resource_name pattern bindings_file binding_arguments

  count=0
  bindings_file=$(mktemp)
  grep -v '^== ' "$dir/rbac.txt" > "$bindings_file"

  while IFS='|' read -r principal role resource_type resource_name pattern; do
    # 去掉每一欄前後的空白
    principal=$(echo $principal)
    role=$(echo $role)
    resource_type=$(echo $resource_type)
    resource_name=$(echo $resource_name)
    pattern=$(echo $pattern)

    # 空行或缺欄位的行跳過
    if [ -z "$principal" ]; then
      continue
    fi

    if [ -z "$role" ]; then
      continue
    fi

    binding_args "$cluster" "$principal" "$role" "$resource_type" "$resource_name" "$pattern"

    if mds_write cli_as svc-ops iam rbac role-binding create "${binding_arguments[@]}" >/dev/null 2>&1; then
      count=$((count + 1))
    else
      fail "binding $principal $role $resource_type:$resource_name"
    fi
  done < "$bindings_file"

  rm -f "$bindings_file"
  ok "role binding：$count 條"

  # 3. SCRAM 帳號：迭代次數照備份、密碼讀 ~/secrets；沒有密碼檔的列出來
  local user iterations missing=""

  count=0

  for user in $(scram_users "$dir"); do
    iterations=$(scram_iterations "$dir" "$user")

    if [ ! -s "$SECRETS_DIR/$user.pass" ]; then
      missing="$missing $user"
      continue
    fi

    if set_scram_password "$user" "${iterations:-iterations=8192}" "$SECRETS_DIR/$user.pass"; then
      count=$((count + 1))
    else
      fail "SCRAM $user"
    fi
  done

  ok "SCRAM 帳號：$count 個"

  # 27.6 已下線的帳號（密碼被覆寫、密碼檔已刪）本來就不該建回來，所以這裡不算失敗（手把手 26.4）
  if [ -n "$missing" ]; then
    warn "沒有密碼檔、沒建回來的 SCRAM 帳號：$missing（27.6 已下線的帳號本來就沒有密碼檔，不是失敗；還在用的帳號要另外發新密碼）"
  fi

  # 4. 配額（有些是只用憑證的帳號，沒有 SCRAM 也有配額）
  local quota quotas_file

  count=0
  quotas_file=$(mktemp)
  quota_lines "$dir" > "$quotas_file"

  while read -r user quota; do
    if kafka-configs "${ADMIN_ARGS[@]}" --alter --entity-type users --entity-name "$user" \
         --add-config "$quota" >/dev/null 2>&1; then
      count=$((count + 1))
    else
      fail "配額 $user"
    fi
  done < "$quotas_file"

  rm -f "$quotas_file"
  ok "配額：$count 個帳號"

  # 5. ACL
  restore_acls "$dir"

  # 6. broker 動態設定（叢集層級的預設值）
  count=0

  for config_value in $(broker_default_configs "$dir"); do
    if kafka-configs "${ADMIN_ARGS[@]}" --alter --entity-type brokers --entity-default \
         --add-config "$config_value" >/dev/null 2>&1; then
      count=$((count + 1))
    else
      fail "broker 設定 $config_value"
    fi
  done

  ok "broker 動態設定：$count 個"
  set +f
}

# drill_remove_bindings <帳號> <topic> <cluster id>：刪掉演練的三條 binding
drill_remove_bindings() {
  local user=$1 topic=$2 cluster=$3 role

  for role in DeveloperRead DeveloperWrite; do
    mds_write cli_as svc-ops iam rbac role-binding delete \
      --principal "User:$user" --role "$role" --resource "Topic:$topic" \
      --kafka-cluster "$cluster" --force >/dev/null 2>&1
  done

  mds_write cli_as svc-ops iam rbac role-binding delete \
    --principal "User:$user" --role DeveloperRead --resource Group:restore- --prefix \
    --kafka-cluster "$cluster" --force >/dev/null 2>&1
}

# drill_remove_account <帳號>：刪掉演練帳號（SCRAM 憑據和配額要分開刪，合在一起 kafka-configs 會整句拒絕）
drill_remove_account() {
  kafka-configs "${ADMIN_ARGS[@]}" --alter --entity-type users --entity-name "$1" \
    --delete-config SCRAM-SHA-512 >/dev/null 2>&1
  kafka-configs "${ADMIN_ARGS[@]}" --alter --entity-type users --entity-name "$1" \
    --delete-config producer_byte_rate,consumer_byte_rate,request_percentage >/dev/null 2>&1
}

# 23.6 演練（lab 與驗收用）：建演練物件 → 備份 → 誤刪 → 還原 → 用該帳號寫讀一筆 → 清掉
drill() {
  local topic=orders.restore-demo
  local user=app-restore
  local cluster dir client_conf role
  local topic_lines principal_lines topics_left bindings_left settings_left left got=0
  local user_password scram_module

  cluster=$(cluster_id)

  # 1. 建演練物件：topic 帶動態設定、帳號帶配額、三條 binding
  section "23.6 還原演練：建演練物件（topic 帶動態設定、帳號帶配額、三條 binding）、備份"

  if ! kafka-topics "${ADMIN_ARGS[@]}" --create --if-not-exists --topic "$topic" \
       --partitions 3 --replication-factor 3 --config retention.ms=3600000 >/dev/null 2>&1; then
    die "建 $topic 失敗"
  fi

  if [ ! -s "$SECRETS_DIR/$user.pass" ]; then
    install -m 0600 /dev/null "$SECRETS_DIR/$user.pass"
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$SECRETS_DIR/$user.pass"
  fi

  if ! set_scram_password "$user" iterations=8192 "$SECRETS_DIR/$user.pass"; then
    die "建 SCRAM $user 失敗"
  fi

  if ! kafka-configs "${ADMIN_ARGS[@]}" --alter --entity-type users --entity-name "$user" \
       --add-config 'producer_byte_rate=1048576,consumer_byte_rate=2097152,request_percentage=25' >/dev/null 2>&1; then
    die "配額失敗"
  fi

  for role in DeveloperRead DeveloperWrite; do
    if ! mds_write cli_as svc-ops iam rbac role-binding create \
         --principal "User:$user" --role "$role" --resource "Topic:$topic" \
         --kafka-cluster "$cluster" >/dev/null 2>&1; then
      die "binding $role 失敗"
    fi
  done

  if ! mds_write cli_as svc-ops iam rbac role-binding create \
       --principal "User:$user" --role DeveloperRead --resource Group:restore- --prefix \
       --kafka-cluster "$cluster" >/dev/null 2>&1; then
    die "binding Group 失敗"
  fi

  # 2. 備份一次，確認演練物件在備份裡
  run_backup
  dir=$(ls -d "$BACKUP_ROOT"/20* | tail -1)
  topic_lines=$(awk -v t="$topic" 'index($0, t) {c++} END {print c + 0}' "$dir/topics.txt")
  principal_lines=$(awk -v p="== User:$user" 'index($0, p) == 1 {c++} END {print c + 0}' "$dir/rbac.txt")

  if [ "$topic_lines" = 0 ]; then
    die "備份裡沒有演練物件"
  fi

  if [ "$principal_lines" != 1 ]; then
    die "備份裡沒有演練物件"
  fi

  ok "備份 $dir 含演練物件"

  # 3. 誤刪
  section "23.6 誤刪：topic、三條 binding、SCRAM 憑據與配額"
  kafka-topics "${ADMIN_ARGS[@]}" --delete --topic "$topic" >/dev/null 2>&1
  drill_remove_bindings "$user" "$topic" "$cluster"
  drill_remove_account "$user"

  # 4. 三樣都沒了
  topics_left=$(kafka-topics "${ADMIN_ARGS[@]}" --list 2>/dev/null \
    | awk -v t="$topic" '$0 == t {c++} END {print c + 0}')
  bindings_left=$(cli_as svc-ops iam rbac role-binding list \
      --principal "User:$user" --kafka-cluster "$cluster" 2>/dev/null \
    | awk -v p="User:$user" 'index($0, p) {c++} END {print c + 0}')
  settings_left=$(kafka-configs "${ADMIN_ARGS[@]}" --describe --entity-type users --entity-name "$user" 2>/dev/null \
    | awk '/./ {c++} END {print c + 0}')
  left="topic $topics_left binding $bindings_left 帳號設定 $settings_left"

  if [ "$left" = "topic 0 binding 0 帳號設定 0" ]; then
    ok "都刪掉了（$left）"
  else
    die "沒刪乾淨：$left"
  fi

  # 5. 從備份還原
  restore "$dir" "$topic" "$user"

  # 6. 用重建的帳號從 9095 寫一筆、讀回來（連線設定借第一個 SCRAM 應用程式那一份，帳密換掉；暫存檔用完即刪）
  section "23.6 驗證：$user 從 9095 寫一筆、讀回一筆；再清掉演練物件"
  client_conf=$(mktemp)
  grep -v '^sasl.jaas.config' "$CONF_DIR/${SCRAM_APPS%% *}.properties" > "$client_conf"
  user_password=$(cat "$SECRETS_DIR/$user.pass")
  scram_module=org.apache.kafka.common.security.scram.ScramLoginModule
  printf 'sasl.jaas.config=%s required username="%s" password="%s";\n' \
    "$scram_module" "$user" "$user_password" >> "$client_conf"

  if echo "restore-$(date +%s)" | kafka-console-producer --bootstrap-server "$BROKER_CLIENT" \
       --producer.config "$client_conf" --topic "$topic" >/dev/null 2>&1; then
    got=$(kafka-console-consumer --bootstrap-server "$BROKER_CLIENT" --consumer.config "$client_conf" \
        --topic "$topic" --group restore-check --from-beginning --max-messages 1 --timeout-ms 20000 2>/dev/null \
      | awk '/restore-/ {c++} END {print c + 0}')
  fi

  rm -f "$client_conf"

  if [ "$got" = 1 ]; then
    ok "$user 寫一筆、讀回 1 筆"
  else
    fail "$user 寫讀失敗（got=$got）"
  fi

  # 7. 清掉演練物件：topic、三條 binding、帳號、密碼檔
  kafka-topics "${ADMIN_ARGS[@]}" --delete --topic "$topic" >/dev/null 2>&1
  drill_remove_bindings "$user" "$topic" "$cluster"
  drill_remove_account "$user"
  rm -f "$SECRETS_DIR/$user.pass"
  log "演練物件已清掉"
}

case $ACTION in
  grant)
    grant
    finish_step
    ;;
  run)
    run_backup
    [ "$FAIL_COUNT" = 0 ]
    ;;
  schedule)
    schedule
    finish_step
    ;;
  compare)
    compare
    ;;
  restore)
    restore "${2:-}" "${3:--}" "${4:--}"
    [ "$FAIL_COUNT" = 0 ]
    ;;
  drill)
    drill
    [ "$FAIL_COUNT" = 0 ]
    ;;
  restore-all)
    restore_all "${2:-}"
    [ "$FAIL_COUNT" = 0 ]
    ;;
  *)
    usage='grant|run|schedule|compare|restore <備份目錄> <topic|-> <帳號|->|drill|restore-all <備份目錄>'
    die "用法：bash $0 $usage"
    ;;
esac
