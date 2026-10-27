#!/usr/bin/env bash
# rest-restart.sh <rest01|rest02> [-c "本機檔案…"] [-b '在那台先執行的指令'] [-r]
# 前提：這台已經由 LB 團隊停用（lb-member.sh <主機> down）。順序：等 LB 那邊進來的連線排空 → -c 的檔案 scp 到那台的 /tmp/
# → 在那台執行 -b → 重啟 confluent-kafka-rest（-r：改成重開機）→ 等到 REST 回 200。排空等不到就停下，什麼都不做
h=$1; shift; copy=""; before=":"; reboot=0
while getopts c:b:r o; do case $o in c) copy=$OPTARG;; b) before=$OPTARG;; r) reboot=1;; *) echo "用法：$0 <主機> [-c 檔案] [-b 指令] [-r]"; exit 2;; esac; done
lb=$(getent hosts lb01.poc.lab | awk '{print $1}')
for waited in $(seq 0 2 60); do n=$(ssh $h.poc.lab "ss -Htn state established '( sport = :8082 )'" | grep -c " $lb:"); [ "$n" = 0 ] && break; sleep 2; done
[ "$n" = 0 ] || { echo "$h：60 秒後 LB 還有 $n 條連線進來，LB 團隊停用了嗎？沒有重啟"; exit 1; }
if [ -n "$copy" ]; then scp -q $copy $h.poc.lab:/tmp/ || { echo "$h：複製檔案失敗，沒有重啟"; exit 1; }; fi
ssh $h.poc.lab "$before" || { echo "$h：重啟前的步驟失敗，沒有重啟"; exit 1; }
start=$(date +%s)
# lab 的主機是容器：共用 WSL2 的核心，systemctl reboot 會失敗（Could not activate remote peer），所以 -r 在容器上改成重啟服務
if [ $reboot = 1 ] && ssh $h.poc.lab 'systemd-detect-virt -cq'; then reboot=0; echo "$h：這台是容器，不能重開機，改重啟 confluent-kafka-rest"; fi
if [ $reboot = 1 ]; then
  ssh $h.poc.lab 'sudo systemctl reboot' 2>/dev/null; sleep 15
  for i in $(seq 1 60); do ssh -o ConnectTimeout=5 $h.poc.lab true 2>/dev/null && break; sleep 5; done
else
  ssh $h.poc.lab 'sudo systemctl restart confluent-kafka-rest'
fi
for i in $(seq 1 60); do
  code=$(curl -s -m 5 --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)
  [ "$code" = 200 ] && break; sleep 3
done
echo "$h：排空等了 ${waited} 秒，$([ $reboot = 1 ] && echo 重開機 || echo 重啟)後 REST $code（約 $(( $(date +%s) - start )) 秒）"
[ "$code" = 200 ]
