#!/usr/bin/env bash
# 收集腳本共用的函式（cbom-collect.sh、webapp/webapp-collect.sh 用 source 載入；裝在 $CBOM_HOME/lib/）。
#
# 收集腳本和後面的程式（cbom-tools.jar）之間只靠「原料目錄」溝通，格式是：
#   <原料>/collect.env        這次的範圍。必要的欄位見 check_raw
#   <原料>/<主機>/            每台主機（或 web app 的 app）一個目錄：tls/、served/、jfr/、java.security …
#   <原料>/shared/            不屬於單一主機的：theia.json、theia-image.json、source/cbom.json、jars/ …
# 哪個檔由 cbom-tools 的哪一層讀（細節在 cbom/tools/src/main/java/lab/cbom/ 各個 Layer 類別的註解）：
#   <主機>/platform-config.properties、secret-protection.properties、ssl-files.list、mds-token-public.pem、
#   shared/scram-users.txt、ssh-host-keys.txt、ssh-client-key.txt            PlatformConfigLayer（只有 Confluent Platform）
#   <主機>/java.security、java-version.txt、java-security-effective.txt、jvm-system-properties.txt、os-crypto.txt
#                                                                            JdkSettingsLayer
#   <主機>/tls/<埠>.json                                                     TlsScanLayer
#   shared/jars/groups.txt、sbom-<雜湊>.json                                  LibraryLayer
#   shared/theia.json                                                        FilesLayer
#   shared/theia-image.json                                                  ImageLayer（只有 web app）
#   shared/source/cbom.json                                                  SourceCodeLayer（只有 web app）
#   <主機>/jfr/*.json                                                        RuntimeLayer（有錄才有）
#
# 這個檔只定義函式，不能單獨執行；沒有自己的結束碼（fail 用呼叫的人給的結束碼結束整支腳本）。

# say <訊息>：進度訊息一律印到 stderr（stdout 留給資料，例如 --tar 的原料），前面加時間
#   例：say "收集完成" → stderr 印「14:03:27 收集完成」
say() {
  echo "$(date +%H:%M:%S) $*" >&2
}

# fail <結束碼> <訊息>：印出「失敗：訊息」後結束整支腳本
#   例：fail 1 "不認得的參數：--x" → stderr 印「14:03:27 失敗：不認得的參數：--x」，結束碼 1
fail() {
  say "失敗：$2"
  exit "$1"
}

# check_raw <原料目錄>：交出去之前的檢查。不合格就 fail 2。
#   1. collect.env 在，必要的欄位都有值
#   2. 沒有任何檔含私鑰內容
#   3. 平台設定裡密碼類的值都遮掉了
check_raw() {
  local raw=$1
  local key value with_key secret_lines unmasked

  if [ ! -f "$raw/collect.env" ]; then
    fail 2 "原料目錄沒有 collect.env：$raw"
  fi

  for key in PROFILE ENV COLLECTED_AT ALL_ROLES ROLES HOSTS; do
    # 取等號右邊整段（cut -f2-：值裡面還有等號也不會被切掉）。例：「ROLES=controller broker」→「controller broker」
    value=$(grep "^$key=" "$raw/collect.env" | cut -d= -f2-)
    if [ -z "$value" ]; then
      fail 2 "collect.env 少了 $key（收集腳本沒有跑完，或這份原料是舊版腳本收的：重新收集）"
    fi
  done

  # 私鑰的 PEM 開頭一定有「PRIVATE KEY」這幾個字（BEGIN PRIVATE KEY、BEGIN RSA PRIVATE KEY …）
  if grep -rlq 'PRIVATE KEY' "$raw"; then
    with_key=$(grep -rl 'PRIVATE KEY' "$raw")
    fail 2 "原料裡有檔案含私鑰內容，不交出去（看收集腳本為什麼取了這些檔）：$with_key"
  fi

  # 平台設定檔裡名稱像密碼的行（web app 沒有這種檔，那就沒有東西要檢查）
  # 樣式：等號左邊（設定名稱）含 password、secret、jaas、credentials 其中一個字
  #   例：「ssl.keystore.password=<遮蔽>」「sasl.jaas.config=<遮蔽>」符合；「ssl.keystore.type=PKCS12」不符合
  local pattern='^[^=]*(password|secret|jaas|credentials)[^=]*='

  secret_lines=
  if grep -rqE "$pattern" "$raw" --include=platform-config.properties; then
    secret_lines=$(grep -rhE "$pattern" "$raw" --include=platform-config.properties)
  fi

  # 數「不是空行、而且值不是 <遮蔽>」的行數；應該是 0
  unmasked=$(echo "$secret_lines" | awk '!/=<遮蔽>/ && NF {c++} END {print c + 0}')  # lint-ok: 計數可能是 0，用 awk 才不會回 1
  if [ "$unmasked" != 0 ]; then
    fail 2 "有 $unmasked 行密碼類設定沒遮到，不交出去（收集腳本遮蔽用的 secrets 樣式要補）：$raw"
  fi
}
