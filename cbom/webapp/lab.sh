#!/usr/bin/env bash
# ============================================================================
# lab.sh：web app 密碼學資產盤點的 lab 環境（一台 Jenkins，工作 cbom-webapp）
#
# 和 Kafka lab、Confluent Platform 的盤點（手冊第 33 章）沒有關係：自己的容器、網路、資料夾、port。
#
#: 用法（Windows Git Bash，在這個專案裡）：
#:   bash cbom/webapp/lab.sh up       建好並啟動 Jenkins（第一次約 5 分鐘：下載兩個工具、建映像）
#:   bash cbom/webapp/lab.sh status   看容器、網址、工具是否齊全
#:   bash cbom/webapp/lab.sh down     收掉容器（加 --purge 連映像、Maven 的 volume、網路一起刪）
#:
#: 需要：podman 的 machine 在跑；cbom/dist/ 已經建好（bash cbom/build.sh，建一次就好）。
#: 產生：~/cbom-lab/tools（下載的 OPA、testssl.sh）、~/cbom-lab/jenkins（Jenkins 的設定、密碼檔、掛進容器的工具）。
#: 管理員帳號 admin，密碼在 ~/cbom-lab/jenkins/secrets/admin.pass（隨機產生，不會印出來）。
#
# 誰在哪裡執行：維護或展示的人，Windows Git Bash（要有 podman、git、curl、openssl、tar）。
# 做完之後：容器 cbom-jenkins（http://localhost:18089）、網路 cbomnet、volume cbom-jenkins-m2（Maven 下載的套件）、
#           映像 cbom-jenkins:1；pipeline 掃原始碼用的映像（ACTION_IMAGE）也先拉好。
# 結束碼：0 成功；1 失敗（訊息以「失敗：」開頭，會說下一步）；64 沒給動作或動作不認得（印用法）；
#         其他非 0 是 podman、curl 自己失敗（set -e）。
# ============================================================================
set -euo pipefail

# 下載的工具與版本（改版本改這裡；testssl.sh 換版本時雜湊也要換）
OPA_VERSION=1.22.3
TESTSSL_VERSION=3.2.5
# testssl.sh 的 release 沒有附雜湊檔：這是 v3.2.5 原始碼包的 sha256
TESTSSL_SHA256=23bb53d50ae093b89631e9fff547c087f632bf35f7a3d7dc78dd4ffff56cd779
ACTION_IMAGE=ghcr.io/cbomkit/cbomkit-action:2.3.0

# 這個 lab 自己的名稱與 port（18089；Kafka lab 的 Jenkins 是另一台 lab-jenkins，port 18088，兩台不相干）
NAME=cbom-jenkins
IMAGE=cbom-jenkins:1
NETWORK=cbomnet
M2_VOLUME=cbom-jenkins-m2
PORT=18089

# 目錄：LAB 可以用環境變數 CBOM_LAB 改；REPO 是這個專案的最上層（從這支腳本的位置問 git）
LAB=${CBOM_LAB:-$HOME/cbom-lab}
TOOLS=$LAB/tools
DIR=$LAB/jenkins
HERE=$(dirname "$0")
REPO=$(git -C "$HERE" rev-parse --show-toplevel)

# podman <參數…>：包一層再呼叫真正的 podman（command podman），其他都一樣
#   Git Bash（Windows）會把 /opt/cbom 這類參數改成 Windows 路徑，對 podman 關掉這個行為
podman() {
  MSYS_NO_PATHCONV=1 command podman "$@"
}

# native <路徑>：印出給 Windows 的程式（curl、podman 的掛載）用的路徑寫法；不是 Windows 就原樣
#   例：native /c/Users/x/cbom-lab/tools → C:/Users/x/cbom-lab/tools
native() {
  if command -v cygpath > /dev/null; then
    cygpath -m "$1"
  else
    echo "$1"
  fi
}

# say <訊息>：印一行進度。例：say "1/4 下載工具"
say() {
  echo "$*"
}

# fail <訊息>：印出「失敗：訊息」到 stderr，結束（結束碼 1）。例：fail "找不到 …：先跑 bash cbom/build.sh"
fail() {
  echo "失敗：$*" >&2
  exit 1
}

# 1. check_dist：我方建置的兩個執行檔（cbom/dist/）要先在；不在就停，訊息說先跑 build.sh
check_dist() {
  if [ ! -f "$REPO/cbom/dist/cbom-tools.jar" ]; then
    fail "找不到 cbom/dist/cbom-tools.jar：先跑 bash cbom/build.sh"
  fi

  if [ ! -f "$REPO/cbom/dist/cbomkit-theia" ]; then
    fail "找不到 cbom/dist/cbomkit-theia：先跑 bash cbom/build.sh"
  fi
}

# 2. download_tools：下載 OPA 與 testssl.sh 到 $TOOLS（已經有、雜湊也對就不重抓）
#    產出 $TOOLS/opa_linux_amd64、$TOOLS/testssl.sh-<版本>.tar.gz；雜湊對不上就刪掉那個檔並停
#    同一個目錄有兩種寫法：$dest（C:/…）給 curl 這個 Windows 程式寫檔用，$TOOLS（/c/…）給 Git Bash 自己的指令用
download_tools() {
  local dest opa_base expected actual testssl_tar testssl_url

  mkdir -p "$TOOLS"
  dest=$(native "$TOOLS")
  opa_base=https://github.com/open-policy-agent/opa/releases/download/v$OPA_VERSION
  testssl_tar=testssl.sh-$TESTSSL_VERSION.tar.gz
  testssl_url=https://github.com/testssl/testssl.sh/archive/refs/tags/v$TESTSSL_VERSION.tar.gz

  # OPA：release 附 .sha256（內容是「雜湊  檔名」，取第 1 欄）；先抓這個小檔知道正確的雜湊
  curl -fsSL -o "$dest/opa.sha256" "$opa_base/opa_linux_amd64.sha256"
  expected=$(cut -d' ' -f1 "$TOOLS/opa.sha256")
  rm -f "$TOOLS/opa.sha256"

  # 已經下載過：算它的雜湊；沒下載過 actual 是空的
  actual=
  if [ -f "$TOOLS/opa_linux_amd64" ]; then
    actual=$(sha256sum "$TOOLS/opa_linux_amd64" | cut -d' ' -f1)
  fi

  # 沒有或雜湊不對：下載，再算一次
  if [ "$actual" != "$expected" ]; then
    curl -fsSL -o "$dest/opa_linux_amd64" "$opa_base/opa_linux_amd64"
    actual=$(sha256sum "$TOOLS/opa_linux_amd64" | cut -d' ' -f1)
  fi

  # 下載之後還是不對：不留這個檔
  if [ "$actual" != "$expected" ]; then
    rm -f "$TOOLS/opa_linux_amd64"
    fail "opa 的 sha256 對不上，已刪掉（下載不完整就再跑一次 up；一直不對就不要用，查 OPA_VERSION 與來源）"
  fi

  say "opa $OPA_VERSION sha256-ok"

  # testssl.sh：GitHub 的版本原始碼包，和上面寫的雜湊（TESTSSL_SHA256）比；三段和 OPA 一樣
  actual=
  if [ -f "$TOOLS/$testssl_tar" ]; then
    actual=$(sha256sum "$TOOLS/$testssl_tar" | cut -d' ' -f1)
  fi

  if [ "$actual" != "$TESTSSL_SHA256" ]; then
    curl -fsSL -o "$dest/$testssl_tar" "$testssl_url"
    actual=$(sha256sum "$TOOLS/$testssl_tar" | cut -d' ' -f1)
  fi

  if [ "$actual" != "$TESTSSL_SHA256" ]; then
    rm -f "$TOOLS/$testssl_tar"
    fail "testssl.sh 的 sha256 對不上，已刪掉（換了 TESTSSL_VERSION 的話 TESTSSL_SHA256 也要換；否則再跑一次 up）"
  fi

  say "testssl.sh $TESTSSL_VERSION sha256-ok"
}

# 3. stage_files：準備掛進容器的目錄 $DIR/cbom（容器裡是 /opt/cbom）：
#    工具、規則、收集腳本、web app 的原始碼，都直接從這個專案拿（每次 up 整個重做，所以改了專案的檔再 up 就會更新）
#      bin/         cbom-tools.jar、cbomkit-theia、cbom-report.sh、opa、testssl/
#      lib/         cbom-lib.sh          policy/      *.rego          VERSIONS
#      webapp/      webapp-collect.sh、Jenkinsfile                    webapp-src/  cbom/app 的原始碼
#    另外產生 $DIR/secrets/admin.pass（Jenkins 管理員的密碼）
stage_files() {
  local home=$DIR/cbom

  rm -rf "$home"
  mkdir -p "$home/bin/testssl" "$home/lib" "$home/policy" "$home/webapp" "$home/webapp-src"
  mkdir -p "$DIR/secrets" "$DIR/init.groovy.d"

  # 專案裡的檔：我方建置的執行檔、版本檔、腳本、規則
  cp "$REPO/cbom/dist/cbom-tools.jar" "$REPO/cbom/dist/cbomkit-theia" "$home/bin/"
  cp "$REPO/cbom/dist/VERSIONS" "$home/VERSIONS"
  cp "$REPO/cbom/cbom-report.sh" "$home/bin/"
  cp "$REPO/cbom/lib/cbom-lib.sh" "$home/lib/"
  cp "$REPO"/cbom/policy/*.rego "$home/policy/"
  cp "$REPO/cbom/webapp/webapp-collect.sh" "$REPO/cbom/webapp/Jenkinsfile" "$home/webapp/"

  # 下載的工具：opa 改名放進 bin/；testssl.sh 解開
  #   --strip-components=1：去掉 tar 裡最外層的目錄 testssl.sh-<版本>/，檔案直接放進 bin/testssl/
  cp "$TOOLS/opa_linux_amd64" "$home/bin/opa"
  tar -xzf "$TOOLS/testssl.sh-$TESTSSL_VERSION.tar.gz" -C "$home/bin/testssl" --strip-components=1

  # web app 的原始碼：cbom/app 現在的檔案（.gitignore 排除的 target/ 不算）
  #   git ls-files -co --exclude-standard：已追蹤（-c）與還沒追蹤但沒被忽略（-o）的檔；
  #   -z 與 tar --null -T -：檔名用 NUL 分隔傳給 tar。括號是子 shell，cd 只在裡面有效
  (
    cd "$REPO/cbom/app"
    git ls-files -co --exclude-standard -z | tar --null -T - -cf -
  ) | tar -xf - -C "$home/webapp-src"

  # 管理員密碼：24 個字的亂數，寫進檔案，不印出來（已經有就沿用）
  #   18 個隨機位元組用 base64 表示剛好 24 個字；tr 去掉結尾的換行字元（\r、\n）
  if [ ! -f "$DIR/secrets/admin.pass" ]; then
    openssl rand -base64 18 | tr -d '\r\n' > "$DIR/secrets/admin.pass"
  fi
}

# 4. build_image：寫出 Containerfile 與啟動時自動設定的 groovy 腳本，建映像 $IMAGE
#    映像：官方 LTS＋plugin＋podman（當用戶端）與 testssl.sh 要用的兩個小工具
#    四個 plugin：workflow-aggregator（pipeline）、credentials-binding、htmlpublisher（顯示報告）、
#    timestamper（Jenkinsfile 的 timestamps()）
#    -Xmx640m：Jenkins 自己的 heap 上限（容器的上限是 start 裡的 2200m，其餘留給 pipeline 跑的 Maven 與掃描工具）
build_image() {
  cat > "$DIR/Containerfile" <<'EOF'
# web app 盤點用的 lab Jenkins：官方 LTS 映像＋pipeline 需要的 plugin 與工具
FROM docker.io/jenkins/jenkins:2.580.2-lts-jdk21
RUN jenkins-plugin-cli --plugins workflow-aggregator credentials-binding htmlpublisher timestamper
# podman（當用戶端，連到主機的引擎）、host 與 hexdump（testssl.sh 要用）
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends podman bind9-host bsdextrautils \
 && rm -rf /var/lib/apt/lists/*
USER jenkins
# podman 一律連到掛進來的 socket
ENV CONTAINER_HOST=unix:///run/podman/podman.sock
# 不跑安裝精靈：帳號與工作由 init.groovy.d 的腳本在啟動時建立
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Xmx640m"
COPY init.groovy.d/ /usr/share/jenkins/ref/init.groovy.d/
EOF

  # Jenkins 每次啟動都會執行 init.groovy.d/ 裡的腳本：建管理員帳號、建（或更新）工作 cbom-webapp
  rm -f "$DIR"/init.groovy.d/*.groovy
  cat > "$DIR/init.groovy.d/cbom-webapp.groovy" <<'EOF'
// 啟動時自動設定：管理員 admin（登入才能用）、工作 cbom-webapp（定義是 /opt/cbom/webapp/Jenkinsfile）
import hudson.security.FullControlOnceLoggedInAuthorizationStrategy
import hudson.security.HudsonPrivateSecurityRealm
import jenkins.model.Jenkins
import org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition
import org.jenkinsci.plugins.workflow.job.WorkflowJob

def jenkins = Jenkins.get()

// 帳號：Jenkins 自己的帳號資料庫（false＝不開放自行註冊），建 admin，密碼讀掛進來的檔
def realm = new HudsonPrivateSecurityRealm(false)
realm.createAccount('admin', new File('/run/lab/admin.pass').text.trim())
jenkins.setSecurityRealm(realm)

// 權限：登入的人什麼都能做，沒登入的人什麼都看不到
def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
jenkins.setAuthorizationStrategy(strategy)

// 工作：沒有就建；pipeline 的內容每次啟動都重新讀 Jenkinsfile（true＝在 Groovy sandbox 裡執行）
def job = jenkins.getItem('cbom-webapp')
if (job == null) {
  job = jenkins.createProject(WorkflowJob, 'cbom-webapp')
}

job.setDefinition(new CpsFlowDefinition(new File('/opt/cbom/webapp/Jenkinsfile').text, true))
job.save()
jenkins.save()
println 'lab：admin、工作 cbom-webapp 已設定'
EOF

  podman build -q -t "$IMAGE" -f "$(native "$DIR/Containerfile")" "$(native "$DIR")" > /dev/null
}

# 5. start：啟動 Jenkins 容器，等到登入頁有回應；3 分鐘沒起來就停
#    自己的網路；掛主機的 podman socket（群組 10 是 podman machine 裡 socket 所屬的 wheel）、Maven 的 volume
#      -p $PORT:8080          主機的 18089 → 容器裡 Jenkins 的 8080
#      -m 2200m               容器的記憶體上限（Jenkins 640m 的 heap＋pipeline 裡的 Maven 建置與工具）
#      /run/lab:ro            管理員密碼檔（唯讀）；/opt/cbom:ro 是 stage_files 準備的那個目錄（唯讀）
#      podman.sock            讓容器裡的 podman（用戶端）叫主機的引擎建映像、跑容器
#      .m2:U                  Maven 下載的套件放 volume，下次不用重抓；:U 把擁有者改成容器裡的 jenkins 帳號
#      --group-add 10、--security-opt label=disable   讓 jenkins 帳號讀寫得到那個 socket
start() {
  local ready=no

  # pipeline 掃原始碼用的映像先拉好（放在這裡，pipeline 第一次跑才不用等下載）
  if ! podman image exists "$ACTION_IMAGE"; then
    podman pull -q "$ACTION_IMAGE"
  fi

  if ! podman network exists "$NETWORK"; then
    podman network create "$NETWORK" > /dev/null
  fi

  # 上次的容器先刪掉再重建（工作的執行紀錄在容器裡，會跟著清掉）
  if podman container exists "$NAME"; then
    podman rm -f "$NAME" > /dev/null
  fi

  podman run -d --name "$NAME" --network "$NETWORK" -p "$PORT:8080" -m 2200m \
    -v "$(native "$DIR/secrets"):/run/lab:ro" \
    -v "$(native "$DIR/cbom"):/opt/cbom:ro" \
    -v /run/podman/podman.sock:/run/podman/podman.sock \
    -v "$M2_VOLUME:/var/jenkins_home/.m2:U" \
    --group-add 10 --security-opt label=disable \
    "$IMAGE" > /dev/null

  # 等登入頁回 200：最多試 36 次、每次隔 5 秒 = 3 分鐘（curl -m 4：一次最多等 4 秒）
  for _ in $(seq 1 36); do
    if curl -s -f -m 4 "http://localhost:$PORT/login" > /dev/null; then
      ready=yes
      break
    fi

    sleep 5
  done

  if [ "$ready" != yes ]; then
    fail "Jenkins 3 分鐘內沒有起來：podman logs $NAME"
  fi
}

# status：印出容器狀態、網址，並進容器確認工具都叫得動（各印一行版本）；最後一行是啟動腳本印的「lab：…已設定」
status() {
  if ! podman container exists "$NAME"; then
    say "沒有容器 $NAME：bash cbom/webapp/lab.sh up"
    return
  fi

  say "容器：$(podman inspect "$NAME" --format '{{.State.Status}}')"
  say "Jenkins：http://localhost:$PORT/job/cbom-webapp/（帳號 admin，密碼在 $DIR/secrets/admin.pass）"
  podman exec -i "$NAME" bash -s <<'EOF'
podman version --format '容器引擎：用戶端 {{.Client.Version}}，主機 {{.Server.Version}}'
echo "cbomkit-theia $(/opt/cbom/bin/cbomkit-theia --help | grep -c 'CBOMkit-theia analyzes')"
echo "testssl.sh $(/opt/cbom/bin/testssl/testssl.sh --version | grep -o '[0-9]*\.[0-9]*\.[0-9]*' | head -1)"
echo "opa $(/opt/cbom/bin/opa version | head -1 | cut -d' ' -f2)"
echo "web app 原始碼：$(ls /opt/cbom/webapp-src | wc -l) 個項目"
EOF
  podman logs "$NAME" 2>&1 | grep '^lab：' | tail -1
}

# up：從檢查前提到啟動，依序做上面的 1.–5.，最後印 status
up() {
  check_dist
  say "1/4 下載工具"
  download_tools
  say "2/4 準備檔案"
  stage_files
  say "3/4 建映像（第一次約 2 分鐘）"
  build_image
  say "4/4 啟動 Jenkins"
  start
  status
}

# down [--purge]：刪掉容器；--purge 另外刪映像、Maven 的 volume、網路（$LAB 的檔案都留著）
#   刪映像、volume、網路時的錯誤訊息丟掉（2>&1）：本來就不存在也照樣印完成訊息
down() {
  podman rm -f --ignore "$NAME" > /dev/null

  if [ "${1:-}" = --purge ]; then
    podman rmi -f "$IMAGE" > /dev/null 2>&1
    podman volume rm -f "$M2_VOLUME" > /dev/null 2>&1
    podman network rm -f "$NETWORK" > /dev/null 2>&1
    say "已收掉（映像、volume、網路也刪了；$LAB 的檔案留著）"
  else
    say "已收掉容器（映像、volume、$LAB 的檔案留著）"
  fi
}

# 第一個參數是動作；沒給或不認得就印出檔頭「#:」開頭的那幾行當用法說明（sed 去掉開頭的「#:」與後面一個空白）
case "${1:-}" in
  up) up ;;
  status) status ;;
  down)
    shift
    down "$@"
    ;;
  *)
    sed -n 's/^#: \{0,1\}//p' "$0"
    exit 64
    ;;
esac
