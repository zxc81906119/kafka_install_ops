#!/usr/bin/env bash
# lb-member.sh <rest01|rest02> down|up|status — lab：扮演 LB 團隊停用／恢復一台 REST Proxy
# 做什麼：在 lb01 的 nginx 設定裡，那一台的 server 行加上（down）或拿掉（up）"down"，再讓 nginx 重新讀設定；status 只印目前狀態
#   正式環境是 LB 團隊在行內的負載平衡設備上停用／啟用 pool member；nginx 重新讀設定時，進行中的連線會讓它跑完
# 用到的設定：lb01 上的 /etc/nginx/stream.d/cp.conf（5.4 寫的），server 行長這樣：server rest01.poc.lab:8082 max_fails=2 fail_timeout=10s;
# 改的時候要注意：輸出的格式（例 "LB：rest01（停用） rest02"）手冊的預期輸出有用到
export MSYS_NO_PATHCONV=1

host=$1
action=${2:-status}
conf=/etc/nginx/stream.d/cp.conf

# lb <指令...>：在 lb01 上執行一個指令
lb() {
  podman exec lab-lb01-1 "$@"
}

# 1. 停用或恢復：改那一台的 server 行
case "$action" in
  down)
    # 還沒有 down 的才加：行尾的 ";" 換成 " down;"
    lb sed -i "/server $host.poc.lab:8082 /{/ down;/!s/;\$/ down;/}" "$conf"
    ;;
  up)
    lb sed -i "/server $host.poc.lab:8082 /s/ down;/;/" "$conf"
    ;;
  status)
    ;;
  *)
    echo "用法：$0 <rest01|rest02> down|up|status"
    exit 2
    ;;
esac

# 2. 改過設定：先檢查語法，再讓 nginx 重新讀設定
if [ "$action" != status ]; then
  if ! lb nginx -t -q; then
    echo "nginx 設定有誤，沒有套用"
    exit 1
  fi

  lb nginx -s reload 2> /dev/null
fi

sleep 1

# 3. 目前狀態：每一台縮成「主機名稱」或「主機名稱（停用）」
#   例：server rest01.poc.lab:8082 max_fails=2 fail_timeout=10s down → rest01（停用）
members=$(lb grep -oE 'server rest0[12][^;]*' "$conf" | sed -E 's/\.poc\.lab:8082 max_fails=2 fail_timeout=10s//; s/server //; s/ down/（停用）/' | paste -sd' ' -)
echo "LB：$members"
