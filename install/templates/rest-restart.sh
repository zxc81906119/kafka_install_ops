#!/usr/bin/env bash
# rest-restart.sh <rest01|rest02> [-c "本機檔案…"] [-b '在那台先執行的指令'] [-r]
# 做什麼：安全地重啟一台 REST Proxy：等 LB 那邊進來的連線排空 → -c 的檔案 scp 到那台的 /tmp/ → 在那台執行 -b
#   → 重啟 confluent-kafka-rest（-r：改成重開機）→ 等到 REST 回 200。排空等不到就停下，什麼都不做
# 前提：這台已經由 LB 團隊停用（lb-member.sh <主機> down）
# 用到的檔案：操作機的 ~/pki/certs/app-legacy-billing.crt 與它的私鑰（用來打 /v3/clusters 確認回 200）
# 改的時候要注意：最後一行輸出（例「rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）」）手冊的預期輸出有用到；結束碼 0 = REST 回 200

host=$1
shift
copy=""
before=":"
reboot=0

# 1. 參數
while getopts c:b:r option; do
  case $option in
    c) copy=$OPTARG ;;
    b) before=$OPTARG ;;
    r) reboot=1 ;;
    *)
      echo "用法：$0 <主機> [-c 檔案] [-b 指令] [-r]"
      exit 2
      ;;
  esac
done

# lb_connections：這台 8082 上從 LB 進來、還連著的連線數
lb_ip=$(getent hosts lb01.poc.lab | awk '{print $1}')

lb_connections() {
  ssh $host.poc.lab "ss -Htn state established '( sport = :8082 )'" | grep -c " $lb_ip:"
}

# 2. 等連線排空：每 2 秒看一次，最多等 60 秒
for waited in $(seq 0 2 60); do
  count=$(lb_connections)

  if [ "$count" = 0 ]; then
    break
  fi

  sleep 2
done

if [ "$count" != 0 ]; then
  echo "$host：60 秒後 LB 還有 $count 條連線進來，LB 團隊停用了嗎？沒有重啟"
  exit 1
fi

# 3. 重啟前：複製檔案、在那台執行指令（任何一個失敗就不重啟）
if [ -n "$copy" ]; then
  if ! scp -q $copy $host.poc.lab:/tmp/; then
    echo "$host：複製檔案失敗，沒有重啟"
    exit 1
  fi
fi

if ! ssh $host.poc.lab "$before"; then
  echo "$host：重啟前的步驟失敗，沒有重啟"
  exit 1
fi

start=$(date +%s)

# 4. 重啟服務（-r：重開機）
#    lab 的主機是容器：共用 WSL2 的核心，systemctl reboot 會失敗（Could not activate remote peer），所以 -r 在容器上改成重啟服務
if [ $reboot = 1 ]; then
  if ssh $host.poc.lab 'systemd-detect-virt -cq'; then
    reboot=0
    echo "$host：這台是容器，不能重開機，改重啟 confluent-kafka-rest"
  fi
fi

if [ $reboot = 1 ]; then
  ssh $host.poc.lab 'sudo systemctl reboot' 2> /dev/null
  sleep 15

  # 等它開回來：每 5 秒試一次 ssh，最多試 60 次
  for i in $(seq 1 60); do
    if ssh -o ConnectTimeout=5 $host.poc.lab true 2> /dev/null; then
      break
    fi

    sleep 5
  done
else
  ssh $host.poc.lab 'sudo systemctl restart confluent-kafka-rest'
fi

# 5. 等 REST 回 200：每 3 秒試一次，最多試 60 次
for i in $(seq 1 60); do
  code=$(curl -s -m 5 --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$host.poc.lab:8082/v3/clusters)

  if [ "$code" = 200 ]; then
    break
  fi

  sleep 3
done

# 6. 結果；不是 200 就以失敗結束
if [ $reboot = 1 ]; then
  action=重開機
else
  action=重啟
fi

echo "$host：排空等了 ${waited} 秒，${action}後 REST $code（約 $(( $(date +%s) - start )) 秒）"

if [ "$code" != 200 ]; then
  exit 1
fi
