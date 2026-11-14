#!/usr/bin/env bash
# ============================================================================
# CBOMkit 平台 demo：用 CBOMkit 掃描我們的 web app，兩套合規檢查並排比較
#
#   網頁 A  http://localhost:28084   CBOMkit 內建的檢查（寫死的規則）
#   網頁 B  http://localhost:28086   OPA 檢查（我們的規則：policy/quantum_safe.rego）
#
#: 用法：
#:   bash cbom/cbomkit-demo/demo.sh up       啟動（約 10 秒；第一次要下載映像檔，需要幾分鐘），印出網址
#:                                           加 --jenkins：Jenkins 也啟動並接上 demo 的網路（要現場跑 web app 的工作 cbom-webapp、上傳到 CBOMkit 時用）
#:   bash cbom/cbomkit-demo/demo.sh scan     不用網頁，直接請 CBOMkit 掃描 web app（網頁操作的備援）
#:   bash cbom/cbomkit-demo/demo.sh check    在終端機比較兩套檢查的結果
#:   bash cbom/cbomkit-demo/demo.sh reload   改了 policy/ 的規則之後，讓 OPA 重新載入（約 5 秒）
#:   bash cbom/cbomkit-demo/demo.sh down     結束：刪掉 demo- 開頭的容器，Jenkins 只停不刪（加 --purge 連掃描紀錄一起刪掉）
#:
#: 需要約 3 GB 可用記憶體：不夠時 up 會停下來，請先停掉其他用不到的容器（確定要硬開就加 --force）。
#
# 名稱、port、版本都在 demo.conf。demo 的步驟與講稿見 README.md。
#
# 誰在哪裡執行：展示的人在 Windows Git Bash（要有 podman、git、curl、openssl；scan／check／reload 另外要 node 20 以上）。
# 輸入：demo.conf、policy/*.rego（OPA 的規則）、cbom/app（要掃描的 web app，取現在的檔案）。
# 輸出：7 個 demo- 開頭的容器（demo-db、demo-builtin-api、demo-builtin-ui、demo-opa、demo-opa-api、demo-opa-ui、
#       demo-git）、網路 $NETWORK、volume demo-db-data（掃描紀錄）、這個目錄的 .env（資料庫密碼，不進 git）。
# 結束碼：0 成功；1 啟動失敗（記憶體不夠、資料庫或 CBOMkit 沒有起來）或 check 失敗；64 沒給動作或動作不認得（印用法）；
#         其他非 0 是 podman、curl 自己失敗（set -e）。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"                  # 之後的路徑都相對於 cbom/cbomkit-demo/
source demo.conf

# podman <參數…>：包一層再呼叫真正的 podman（command podman），其他都一樣
#   Git Bash（Windows）會把 /policies 這類參數改成 Windows 路徑，對 podman 關掉這個行為
podman() {
  MSYS_NO_PATHCONV=1 command podman "$@"
}

# here：印出現在的目錄，寫成 podman 掛載資料夾要用的主機路徑
#   例：Git Bash 裡 /c/Users/x/cbom/cbomkit-demo → C:/Users/x/cbom/cbomkit-demo（pwd -W）；Linux 上原樣
here() {
  if pwd -W > /dev/null 2>&1; then
    pwd -W
  else
    pwd
  fi
}

# wait_url <說明> <網址> <容器名稱>：等到某個網址回應；等不到就說要看哪個容器的 log，結束
#   例：wait_url "Jenkins" http://localhost:18089/login cbom-jenkins →「  等待 Jenkins ....OK」
#   最多試 60 次、每次隔 3 秒 = 3 分鐘
wait_url() {
  printf '  等待 %s ' "$1"
  for _ in $(seq 60); do
    if curl -fs "$2" > /dev/null; then
      echo OK
      return
    fi

    printf .
    sleep 3
  done

  echo
  echo "啟動失敗：$1 3 分鐘內沒有回應 $2"
  echo "看 log：podman logs $3（處理後 bash cbom/cbomkit-demo/demo.sh down 再 up 一次）"
  exit 1
}

# 一組 CBOMkit = API + 網頁。用法：start_cbomkit <名稱> <API port> <網頁 port> <網頁標題> [API 的其他參數]
#   例：start_cbomkit demo-opa 28085 28086 "CBOMkit-OPA檢查" -e CBOMKIT_OPA_API_BASE=http://demo-opa:8181
#       → 容器 demo-opa-api（主機的 28085）與 demo-opa-ui（主機的 28086）
# （網頁標題不能有空白：網頁映像檔用 sed 代換標題，遇到空白會失敗）
# 兩組都連到同一個資料庫，所以掃描結果兩邊都看得到
# 記憶體上限（--memory）：API 2g、網頁 256m；每個容器都設上限，單一容器失控時不會把引擎那台機器的記憶體吃光
start_cbomkit() {
  local name=$1 api_port=$2 ui_port=$3 title=$4

  # 前 4 個參數取走之後，"$@" 剩下的就是「API 的其他參數」
  shift 4
  podman run -d --name "$name-api" --network "$NETWORK" -p "$api_port:8081" --memory 2g \
    -e CBOMKIT_PORT=8081 -e CBOMKIT_DB_TYPE=postgresql \
    -e CBOMKIT_DB_JDBC_URL="jdbc:postgresql://demo-db:5432/postgres" \
    -e CBOMKIT_DB_USERNAME=cbomkit -e CBOMKIT_DB_PASSWORD="$DB_PASSWORD" \
    -e CBOMKIT_FRONTEND_URL_CORS="http://localhost:$ui_port" \
    -e CBOMKIT_JAVA_JAR_DIR=/deployments/java/scan/ \
    "$@" "$CBOMKIT_API_IMAGE" > /dev/null

  # 網頁是在瀏覽器裡呼叫 API，所以 API 網址用 localhost
  podman run -d --name "$name-ui" --network "$NETWORK" -p "$ui_port:8000" --memory 256m \
    -e VUE_APP_HTTP_API_BASE="http://localhost:$api_port" -e VUE_APP_WS_API_BASE="ws://localhost:$api_port" \
    -e VUE_APP_TITLE="$title" -e VUE_APP_VIEWER_ONLY=false "$CBOMKIT_UI_IMAGE" > /dev/null
}

# CBOMkit 只接受 http(s) 的 git 網址：把 web app（cbom/app）做成一個只有它的 git repo，放進 nginx 提供。
# 內容是 cbom/app 現在的檔案（已 commit 與還沒 commit 的都算；.gitignore 排除的 target/ 不算）
# serve_repo：沒有參數；做完之後 CBOMkit 的容器可以用 $GIT_URL（http://demo-git/local/crypto-lab）clone
serve_repo() {
  local app

  # 1. 把 cbom/app 的檔案複製到暫存目錄 .repo/work
  #    git ls-files -co --exclude-standard：列出已追蹤（-c）與還沒追蹤但沒被忽略（-o）的檔；
  #    -z 與 tar --null -T -：檔名用 NUL 分隔傳給 tar，檔名有空白也不會出錯。括號是子 shell，cd 只在裡面有效
  app="$(git rev-parse --show-toplevel)/cbom/app"
  rm -rf .repo
  mkdir -p .repo/work
  (
    cd "$app"
    git ls-files -co --exclude-standard -z | tar --null -T - -cf -
  ) | tar -xf - -C .repo/work

  # 2. 做成只有一個 commit 的 git repo，再轉成給伺服器放的格式（bare）
  git -C .repo/work init -q -b "$APP_BRANCH"
  git -C .repo/work config core.autocrlf false          # 檔案照原樣放進去，不轉換行字元
  git -C .repo/work add -A
  git -C .repo/work -c user.name=demo -c user.email=demo@localhost commit -q -m "cbom/app"
  git clone -q --bare .repo/work .repo/crypto-lab
  git -C .repo/crypto-lab update-server-info          # 讓 git 可以用純 HTTP clone

  # 3. 放進 nginx 容器（記憶體上限 64m），刪掉暫存目錄
  podman run -d --name demo-git --network "$NETWORK" --memory 64m "$GIT_IMAGE" > /dev/null
  podman exec demo-git mkdir -p /usr/share/nginx/html/local
  podman cp "$(here)/.repo/crypto-lab" demo-git:/usr/share/nginx/html/local/
  rm -rf .repo
}

# 可用記憶體不夠就不啟動：容器引擎的機器記憶體吃緊時會整台卡住。看的是引擎那台機器的 MemAvailable
# check_memory <yes|no>：參數是「有沒有加 --force」。夠就直接回來；不夠時印出訊息，no 就結束（1），yes 照樣繼續
check_memory() {
  local available

  # 開一個臨時容器讀 /proc/meminfo（容器看到的是引擎那台機器的數字），單位 kB，換成 MB
  #   例：「MemAvailable:    4563210 kB」→ 多個空白併成一個 → 第 2 欄 4563210 → 4456
  available=$(podman run --rm "$GIT_IMAGE" grep MemAvailable /proc/meminfo | tr -s ' ' | cut -d' ' -f2)
  available=$((available / 1024))
  if [ "$available" -ge "$NEED_MEMORY_MB" ]; then
    return
  fi

  echo "可用記憶體 $available MB，不到 $NEED_MEMORY_MB MB：先停掉其他用不到的容器（podman ps 看有哪些）再啟動。"
  if [ "$1" = yes ]; then
    echo "加了 --force：照樣啟動"
    return
  fi

  exit 1
}

# up [--jenkins] [--force]：先收掉上次的，再依序啟動資料庫、兩組 CBOMkit、OPA、git 伺服器，最後印出網址
up() {
  local jenkins=no force=no option
  local waited

  for option in "$@"; do
    case "$option" in
      --jenkins) jenkins=yes ;;
      --force) force=yes ;;
    esac
  done

  down > /dev/null
  check_memory "$force"

  # web app 的 Jenkins（cbom/webapp/lab.sh 建的）：一起啟動，之後接上這個 demo 的網路
  if [ "$jenkins" = yes ]; then
    if podman container exists "$JENKINS_CONTAINER"; then
      podman start "$JENKINS_CONTAINER" > /dev/null
    else
      echo "找不到容器 $JENKINS_CONTAINER：先跑 bash cbom/webapp/lab.sh up；這次略過"
      jenkins=no
    fi
  fi

  # 資料庫密碼：第一次自動產生（24 個十六進位字），存在 .env（不進 git），之後沿用
  if [ ! -f .env ]; then
    echo "DB_PASSWORD=$(openssl rand -hex 12)" > .env
  fi

  source .env

  # demo 自己的網路（容器之間用名稱互連，例如 demo-db、demo-opa）
  if ! podman network exists "$NETWORK"; then
    podman network create "$NETWORK" > /dev/null
  fi

  echo "1/4 資料庫"
  podman run -d --name demo-db --network "$NETWORK" --memory 512m --user postgres \
    -e POSTGRES_DB=postgres -e POSTGRES_USER=cbomkit -e POSTGRES_PASSWORD="$DB_PASSWORD" \
    -v demo-db-data:/var/lib/postgresql/data "$DB_IMAGE" > /dev/null

  # 等資料庫可以連線：每秒問一次，最多 60 次；一分鐘還連不上就不再等，印出要看哪個 log 後結束
  waited=0
  until podman exec demo-db pg_isready -q; do
    waited=$((waited + 1))
    if [ "$waited" -ge 60 ]; then
      echo "資料庫沒有起來：podman logs demo-db"
      exit 1
    fi

    sleep 1
  done

  echo "2/4 CBOMkit（內建檢查）"
  start_cbomkit demo-builtin "$BUILTIN_API_PORT" "$BUILTIN_UI_PORT" "CBOMkit-內建檢查"

  echo "3/4 OPA + CBOMkit（OPA 檢查）"
  # OPA 啟動時讀 policy/ 的規則；改了規則要執行 reload（不用 --watch：檔案在 Windows 上，容器收不到「檔案改了」的通知）
  podman run -d --name demo-opa --network "$NETWORK" --memory 256m \
    -v "$(here)/policy:/policies:ro,Z" "$OPA_IMAGE" run --server --addr :8181 /policies > /dev/null
  start_cbomkit demo-opa "$OPA_API_PORT" "$OPA_UI_PORT" "CBOMkit-OPA檢查" -e CBOMKIT_OPA_API_BASE=http://demo-opa:8181

  echo "4/4 提供 web app 的 git repo"
  serve_repo

  wait_url "CBOMkit（內建檢查）" "http://localhost:$BUILTIN_API_PORT/api" demo-builtin-api
  wait_url "CBOMkit（OPA 檢查）" "http://localhost:$OPA_API_PORT/api" demo-opa-api

  echo
  echo "Demo is up."
  echo "  網頁 A（內建檢查）: http://localhost:$BUILTIN_UI_PORT"
  echo "  網頁 B（OPA 檢查）: http://localhost:$OPA_UI_PORT"
  echo "  要掃描的 git 網址 : $GIT_URL"

  if [ "$jenkins" = yes ]; then
    # Jenkins 接上 demo 的網路，工作才能把 CBOM 上傳到 CBOMkit（已經接著會回錯誤，不用理它）
    if podman network connect "$NETWORK" "$JENKINS_CONTAINER" 2> /dev/null; then
      echo "  Jenkins 已接上 demo 的網路"
    fi

    wait_url "Jenkins" "http://localhost:$JENKINS_PORT/login" "$JENKINS_CONTAINER"
    echo "  Jenkins            : http://localhost:$JENKINS_PORT/job/cbom-webapp/"
    echo "  工作的 CBOMKIT_URL : http://demo-builtin-api:8081（內建檢查）或 http://demo-opa-api:8081（OPA 檢查）"
  fi
}

# scan：請 CBOMkit 掃描 web app 的 git repo，等結果出來後印出兩套檢查的比較（和 check 同樣的表）
# 和網頁的 Scan 按鈕呼叫同一個 API；掃描在背景進行，check.mjs --wait 會等到結果出現
scan() {
  echo "掃描 $GIT_URL（$APP_BRANCH）…"
  curl -fs -X POST "http://localhost:$BUILTIN_API_PORT/api/v1/scan" -H 'Content-Type: application/json' \
    -d "{\"scanUrl\": \"$GIT_URL\", \"branch\": \"$APP_BRANCH\"}" > /dev/null
  node check.mjs --wait
}

# reload：改了 policy/ 的規則之後讓 OPA 用新規則。OPA 只在啟動時讀規則，所以重新啟動它。
# CBOMkit 會沿用重啟前和 OPA 的連線，重啟後頭一兩次合規檢查會失敗：先呼叫到成功為止，網頁才不會碰到錯誤
# （最多試 10 次、每次隔 1 秒；10 次都不成功也照樣印出完成訊息，那時用 demo.sh check 看錯在哪）
reload() {
  podman restart demo-opa > /dev/null
  for _ in $(seq 10); do
    if node check.mjs > /dev/null 2>&1; then
      break
    fi

    sleep 1
  done

  echo "OPA reloaded policy/（重新整理網頁 B 就是新規則的結果）"
}

# down [--purge]：刪掉 demo- 開頭的 7 個容器，Jenkins 只停不刪；--purge 另外刪掉掃描紀錄（volume）與資料庫密碼檔
down() {
  local purge=no option

  for option in "$@"; do
    case "$option" in
      --purge) purge=yes ;;
    esac
  done

  # 先刪用資料庫的（網頁、API），再刪 OPA、git 伺服器、資料庫；--ignore：不存在也不算錯
  podman rm -f --ignore demo-builtin-ui demo-builtin-api demo-opa-ui demo-opa-api > /dev/null
  podman rm -f --ignore demo-opa demo-git demo-db > /dev/null

  # web app 的 Jenkins 也停掉（只停不刪，執行紀錄留著；下次 up --jenkins 會再啟動）
  if podman container exists "$JENKINS_CONTAINER"; then
    podman stop "$JENKINS_CONTAINER" > /dev/null
  fi

  if [ "$purge" = yes ]; then
    podman volume rm -f demo-db-data > /dev/null
    rm -f .env
    echo "demo stopped (purged)"
  else
    echo "demo stopped"
  fi
}

# 第一個參數是動作；up 與 down 把後面的選項（--jenkins、--force、--purge）傳給函式
# 沒給或不認得：印出檔頭「#:」開頭的那幾行當用法說明（sed 去掉開頭的「#:」與後面一個空白）
case "${1:-}" in
  up)
    shift
    up "$@"
    ;;
  scan)
    scan
    ;;
  check)
    node check.mjs
    ;;
  reload)
    reload
    ;;
  down)
    shift
    down "$@"
    ;;
  *)
    sed -n 's/^#: \{0,1\}//p' "$0"
    exit 64
    ;;
esac
