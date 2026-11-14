#!/usr/bin/env bash
# lab-power.sh：把 Kafka lab 的容器整組停掉，或照順序啟動回來（lab 專用；只停不刪，資料與設定都留著）
#
# 什麼時候用：這台機器的記憶體要讓給別的工作時先 stop，做完再 start。
# 用法（Windows Git Bash）：
#   bash install/lab/lab-power.sh stop      停掉所有名稱以 lab- 開頭、正在跑的容器
#   bash install/lab/lab-power.sh start     照順序啟動：周邊 → controller → broker 與操作機 → REST Proxy、Control Center、Jenkins
#   bash install/lab/lab-power.sh status    每種容器各有幾個在跑、平台的服務是否 active
# 順序的原因：broker 要等 controller 的 quorum；REST Proxy 與 Control Center 要等 broker 與 MDS。
#
# 誰在哪裡執行：維護 lab 的人，Windows Git Bash（podman 的 machine 要在跑）。
# 輸入：沒有檔案；容器名稱寫在下面四個變數（多一台或少一台要改這裡）。輸出：只有畫面上的訊息，不產生檔案。
# 結束碼：0 成功；1 start 時這台機器沒有 Kafka lab，或服務 5 分鐘內沒有全部起來（訊息會列出是哪幾台）；
#         64 沒給動作或動作不認得（印出上面的用法）；其他非 0 是 podman 自己失敗（set -e）。
set -euo pipefail
# Git Bash 會把 / 開頭的參數改成 Windows 路徑：對這支腳本裡的 podman 全部關掉
export MSYS_NO_PATHCONV=1

# 四組容器，照啟動的先後；ops02 和 broker 放同一組。lab-jenkins 是 Kafka lab 裡的 Jenkins（手冊 33.10，工作 cbom）
BASE="lab-ad01-1 lab-repo01-1 lab-lb01-1"
CONTROLLERS="lab-kc01-1 lab-kc02-1 lab-kc03-1"
BROKERS="lab-kb01-1 lab-kb02-1 lab-kb03-1 lab-kb04-1 lab-ops02-1"
FRONT="lab-rest01-1 lab-rest02-1 lab-c3-01-1 lab-jenkins"

# 啟動後要確認的服務：容器:服務（一行太長，分四次接起來）
CHECKS="lab-kc01-1:confluent-server lab-kc02-1:confluent-server lab-kc03-1:confluent-server"
CHECKS="$CHECKS lab-kb01-1:confluent-server lab-kb02-1:confluent-server lab-kb03-1:confluent-server"
CHECKS="$CHECKS lab-kb04-1:confluent-server lab-rest01-1:confluent-kafka-rest lab-rest02-1:confluent-kafka-rest"
CHECKS="$CHECKS lab-c3-01-1:confluent-control-center"

# running_names：印出正在跑的 Kafka lab 容器名稱，一行一個（grep 沒找到會回 1，所以用 sed 挑）
#   sed -n '/^lab-/p'：只印 lab- 開頭的行。例：「lab-kb01-1」「lab-mon-grafana」印出來；「demo-db」「cbom-jenkins」不印
running_names() {
  podman ps --format '{{.Names}}' | sed -n '/^lab-/p'
}

# start_group <容器…>：只啟動存在的容器（例如沒做過手冊 33.10 就沒有 lab-jenkins）
#   例：start_group lab-kc01-1 lab-kc02-1 lab-kc03-1
start_group() {
  local name

  for name in "$@"; do
    if podman container exists "$name"; then
      # 和 podman 的連線偶爾會斷一下（2026-11-12 遇過一次）：失敗就等 5 秒再試一次
      if ! podman start "$name" > /dev/null; then
        sleep 5
        podman start "$name" > /dev/null
      fi
    fi
  done
}

# stop_group <容器…>：這幾個容器同時停（各自最多等 60 秒），全部停好才回來；不存在的略過
#   例：stop_group lab-rest01-1 lab-rest02-1
#   -t 60：給容器裡的服務最多 60 秒正常結束，超過才強制停；結尾的 & 是放到背景，wait 等這一組全部停完
stop_group() {
  local name

  for name in "$@"; do
    if podman container exists "$name"; then
      podman stop -t 60 "$name" > /dev/null &
    fi
  done

  wait
}

# not_active：印出還沒 active 的服務所在的容器，空白隔開；都 active 就是空字串
#   例：kb04 還沒好 → 印「 lab-kb04-1」；容器沒在跑也算還沒 active
not_active() {
  local check container unit waiting=""

  for check in $CHECKS; do
    # 把「容器:服務」拆開。例：lab-kb01-1:confluent-server
    #   ${check%%:*} 去掉第一個冒號以後 → lab-kb01-1；${check##*:} 去掉最後一個冒號以前 → confluent-server
    container=${check%%:*}
    unit=${check##*:}
    if ! podman exec "$container" systemctl is-active --quiet "$unit" 2> /dev/null; then
      waiting="$waiting $container"
    fi
  done

  echo "$waiting"
}

# stop：照啟動的相反順序一組一組停，最後停剩下所有 lab- 開頭的容器
stop() {
  local running

  running=$(running_names)
  if [ -z "$running" ]; then
    echo "Kafka lab 沒有在跑的容器"
    return
  fi

  echo "停掉 Kafka lab：$(echo "$running" | wc -l) 個容器（只停不刪，約 2 分鐘）"

  # 照啟動的相反順序，一組一組停；同一組的容器同時停（一個一個停要 7 分鐘）
  # $FRONT 這幾個變數故意不加引號：要讓 bash 照空白拆成一個一個容器名稱
  # （「# shellcheck disable=…」是給檢查工具 shellcheck 看的，告訴它這裡不加引號是故意的）
  # shellcheck disable=SC2086
  stop_group $FRONT
  # shellcheck disable=SC2086
  stop_group $BROKERS
  # shellcheck disable=SC2086
  stop_group $CONTROLLERS

  # 剩下的（周邊、監控等其他 lab- 開頭的容器）
  # shellcheck disable=SC2046
  stop_group $(running_names)
  echo "已停掉"
}

# start：照順序啟動四組，再等平台的服務都 active；5 分鐘內沒有全部起來就列出是哪幾台，回 1
start() {
  local waiting

  if ! podman container exists lab-kb01-1; then
    echo "這台機器沒有 Kafka lab 的容器（手冊第 0 章建）"
    exit 1
  fi

  echo "啟動 Kafka lab（照順序，約 4 分鐘）"

  # 周邊（AD、套件庫與 NTP、負載平衡）與 controller
  # shellcheck disable=SC2086
  start_group $BASE
  # shellcheck disable=SC2086
  start_group $CONTROLLERS

  # 等 45 秒讓三台 controller 選出 quorum，再啟動 broker（這裡只是固定等，沒有檢查；真正的確認在最後的迴圈）
  sleep 45
  # shellcheck disable=SC2086
  start_group $BROKERS

  # 等 90 秒讓 broker 與 MDS 起來，再啟動 REST Proxy、Control Center、Jenkins（同樣只是固定等）
  sleep 90
  # shellcheck disable=SC2086
  start_group $FRONT

  # 等平台的服務起來：每 10 秒看一次，最多 30 次 = 5 分鐘
  for _ in $(seq 1 30); do
    waiting=$(not_active)
    if [ -z "$waiting" ]; then
      echo "Kafka lab 的服務都起來了"
      return
    fi

    sleep 10
  done

  # 到這裡表示 5 分鐘還沒全部 active。下一步：進那台看服務為什麼沒起來，例如
  #   podman exec lab-kb01-1 systemctl status confluent-server（broker 另外看 /var/log/kafka/ 的 log）
  echo "這幾台的服務還沒起來，自己再看一下：$waiting"
  exit 1
}

# status：印出正在跑的 lab- 容器有幾個、平台的服務是不是都 active（只看不改）
status() {
  local names waiting

  names=$(running_names)
  if [ -z "$names" ]; then
    echo "Kafka lab 沒有在跑的容器"
    return
  fi

  echo "在跑的容器：$(echo "$names" | wc -l) 個"
  waiting=$(not_active)
  if [ -z "$waiting" ]; then
    echo "平台的服務都是 active"
  else
    echo "服務不是 active 的：$waiting"
  fi
}

# 第一個參數是動作；沒給或不認得就印出檔頭第 2 到 9 行（用途與用法）
case "${1:-}" in
  stop) stop ;;
  start) start ;;
  status) status ;;
  *)
    sed -n '2,9p' "$0"
    exit 64
    ;;
esac
