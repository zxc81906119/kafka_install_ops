#!/usr/bin/env bash
# 測 91 緊急模式挑 MDS:逐台問 /v1/metadata/id,用第一台回 200 的換 token;全部連不上就停下並指向 kafka-admin(SCRAM)的程序。
# 不需要叢集:be_http、secret_get 與 Kafka 工具以假的函式代替。
#   ./test-breakglass-mds.sh      全部通過印 "ALL PASS",有失敗回傳 1
if ! cd "$(dirname "$0")/.."; then
  exit 1
fi

export OPMENU_HOME="$PWD" OPMENU_LOG="$(mktemp)" OPMENU_SYSLOG=0 OPMENU_ALLOW_ENV_OVERRIDE=1
. lib/defaults.sh
. lib/common.sh
. lib/kafka.sh

OPMENU_MDS_URL='https://kb01.poc.lab:8090,https://kb02.poc.lab:8090,https://kb03.poc.lab:8090'
OPMENU_BREAKGLASS_PEM=/dev/null
OPMENU_BREAKGLASS_BOOTSTRAP='kb01.poc.lab:9094'
OPMENU_TMPDIR="$(mktemp -d)"
OPMENU_TRUSTSTORE=/dev/null
OPMENU_TRUSTSTORE_PASSWORD_FILE="$(mktemp)"
OP_LAST_RAW="$(mktemp)"

secret_get() {
  printf -- '-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\n'
  printf -- '-----BEGIN CERTIFICATE-----\ny\n-----END CERTIFICATE-----\n'
}

# 哪幾台 MDS 活著由 UP 決定;假的 Kafka 工具把收到的連線設定裡的 metadataServerUrls 印出來
UP=""

be_http() {
  local u="${*: -1}"

  case " $UP " in
    *" ${u%%/v1/*} "*) echo 200 ;;
    *) echo 000 ;;
  esac
}

fake-tool() {
  local c

  while [ $# -gt 0 ]; do
    if [ "$1" = --command-config ]; then
      c=$2
    fi
    shift
  done

  grep -o 'metadataServerUrls="[^"]*"' "$c"
}

fails=0
check() {
  if eval "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    fails=$((fails+1))
  fi
}

UP="https://kb01.poc.lab:8090 https://kb02.poc.lab:8090 https://kb03.poc.lab:8090"
out=$(be_bootstrap_kafka fake-tool --list 2>&1)
rc=$?
check "三台都活著:用第一台" '[ $rc = 0 ] && [[ "$out" == *"metadataServerUrls=\"https://kb01.poc.lab:8090\""* ]]'

UP="https://kb02.poc.lab:8090 https://kb03.poc.lab:8090"
out=$(be_bootstrap_kafka fake-tool --list 2>&1)
rc=$?
check "kb01 的 MDS 掛了:改用 kb02(原本會一直用 kb01 而失敗)" \
  '[ $rc = 0 ] && [[ "$out" == *"metadataServerUrls=\"https://kb02.poc.lab:8090\""* ]]'

UP=""
out=$(be_bootstrap_kafka fake-tool --list 2>&1)
rc=$?
check "全部連不上:不執行、回傳失敗" '[ $rc -ne 0 ] && [[ "$out" != *metadataServerUrls* ]]'
check "全部連不上:告訴操作者改用 kafka-admin(SCRAM)" '[[ "$out" == *"kafka-admin"* ]]'
check "暫存的憑證與設定檔都刪掉了" '[ -z "$(ls -A "$OPMENU_TMPDIR")" ]'

rm -rf "$OPMENU_LOG" "$OPMENU_TMPDIR" "$OPMENU_TRUSTSTORE_PASSWORD_FILE" "$OP_LAST_RAW"

if [ "$fails" = 0 ]; then
  echo "ALL PASS"
else
  echo "$fails 項失敗"
  exit 1
fi
