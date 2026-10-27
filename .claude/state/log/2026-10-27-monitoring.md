# 2026-10-27 監控改成外部 Prometheus／Alertmanager／Grafana + JMX exporter

使用者決定與細節：redesign/README.md「監控改成外部 Prometheus／Alertmanager／Grafana + JMX exporter（2026-10-27 定案）」。本檔記做了什麼、怎麼驗、哪裡沒驗。**沒有 commit。**

## 開場狀況
- 交辦時說 Docker Desktop 開著、lab 是舊安裝但叢集在跑。實際：Docker 沒開，我啟動 Docker Desktop；14 個容器 cold boot 後 controller／broker／REST／C3 全部因 `java.net.UnknownHostException: conjur.poc.lab`（`20-conjur.conf` 的 CLASSPATH 加 properties 裡的 Conjur 參照）crash loop（約佔 800% CPU）。
- 依規則沒有修。嘗試用 \`systemctl stop\` 止住 crash loop 被權限系統擋下，沒有繞過，crash loop 一直在跑（對我的測速有影響）。
- ops02 的 ssh-agent 死了（cold boot），用 \`~/kafka-lab/pvwa/cpadmin_ed25519\` 重新貼進 \`engineer-agent.sock\`（手把手 3.1 的做法）。

## 驗證環境（拋棄式，全是我建的）
- 映像 \`lab-mon-cp:1\`（lab-node:1 + JDK 21 tar + Confluent 8.3.2 全部 RPM；\`rpm -i --nodeps\`）。容器：\`lab-mon-kc\`（controller，dynamic quorum \`--standalone\`）、\`lab-mon-kb\`（broker）、\`lab-mon-rest\`（REST Proxy，HTTP）、\`lab-mon-c3\`（C3 2.6.1 + 它自己的 prometheus／alertmanager，LOCAL_MODE，連 lab-mon-kb）。固定 IP 172.35.0.201–204，主機名 kc01／kb01／rest01／c3-01 對 Prometheus 容器的 \`--add-host\`。
- exporter 設定與 jar 取自 ops02（和真實主機派送的同一份），用同一張 \`cp-server.p12\`／\`kafka-internal.p12\`（SAN 涵蓋所有主機名），所以 HTTPS 用銀行根憑證驗鏈、basic auth 加鹽 SHA-256 都是真的。
- 負載：\`payments.perf\` 3 partition，kafka-producer-perf-test 30 萬筆、一個 consumer group。
- 沒有：RBAC／MDS／audit／quota／Self-Balancing／多台 controller／多台 broker。

## 真實主機上做的事（ops02 → 10 台）
- 17.3 派送：jar、\`jmx-exporter.yml\`（controller 158 行、broker 436、REST 54、C3 36）、\`40-jmx.conf\`、daemon-reload，\`systemctl show -p Environment\` 看到 javaagent。C3 的 \`/etc/confluent/control-center/jmx-exporter.yml\` 與 \`40-jmx.conf\`（\`CONTROL_CENTER_OPTS\`）是新的。**沒有重啟。**
- 踩到：舊腳本與我第一版的 \`sudo wc -l < 檔\`（\`<\` 用呼叫者身分開檔 → Permission denied）；已修 \`install/steps/17-jmx-exporter.sh\`。

## 結果
- target：4 個 job 各 1 個 up（其餘 6 個是真叢集主機，down 是預期的，TargetDown 正確觸發並送到兩個 webhook）。
- 規則：21 條，promtool SUCCESS；每條的指標在 Prometheus 裡存在。
- Grafana 11.3.0：32 個 dashboard 佈建；datasource 健康；\`/api/ds/query\` 查「Current Leader」回 1。
- 覆蓋率（\`docs/journey-src/tools/dashboard-coverage.py\`）：32 個 dashboard、816 panel、253 有資料。細項在手把手 17.9 與 redesign。
- webhook：預設格式與自訂格式（Dynatrace 欄位）都收到；\`description\` 含雙引號、冒號、\`007\` 完整；resolved 兩種格式都收到（約 3–5 分鐘，因為被拿掉的規則不會補送 resolved）。
- C3 的 JVM：約兩萬條序列；放行後約 100 條。client_state 的 bean 欄位順序不固定，pattern 要寫 \`kafka.streams<.*client-id=([^,>]+).*>\`。同一個 JVM 放兩個 \`-javaagent\` 會讓 \`control-center-run-class\` 的 \`-check_dir\` 失敗（\`java.io.tmpdir=\` 空）。
- **推翻**：官方規則抓得到 \`kafka_server_raft_metrics_*\`（controller 17 條、broker 15 條）。

## 改了哪些檔
- 手把手：\`docs/journey-src/journey.md\`（第 0.2／0.4、1.4、1.6、2.2、2.3、7、13、14、17 整章、19、20、23）、\`diagrams.js\`（\`D.jmx\` 重畫）、\`tools/dashboard-coverage.py\`（新）、\`tools/run-full.sh\`（從零先收 lab-mon-*）。
- install：\`steps/17-jmx-exporter.sh\`（重寫）、\`steps/01-download.sh\`、\`02-intake.sh\`、\`07-os-tuning.sh\`（c3 開 7071）、\`19-acceptance.sh\`（c3-01 的 7071）、\`conf/site.env\`（\`MONITOR_ENV_LABEL\`、\`MONITORING_STACKS_COMMIT\`）、\`lab/bank-sim.sh\`（\`monitoring\`、\`monitoring-stop\`，\`reset\` 先收）、\`README.md\`。
- 範本：新增 \`confluent-alerts.yml\`、\`alertmanager.yml\`、\`grafana-datasource.yml\`、\`jmx-rules-c3.yml\`；改 \`jmx-header.yml\`、\`prometheus-scrape.yml\`；刪 \`jmx-rules-kafka.yml\`、\`jmx-rules-rest.yml\`、\`alert-rules.yml\`。
- 文件：\`docs/questions-src/questions.md\`（2.1、2.3、11.1、新增 11.5–11.8、12 附件；已重建 docx）、\`redesign/README.md\`、\`README.md\`、\`CLAUDE.md\`、\`.claude/skills/manual-step/SKILL.md\`。
- \`bash install/tools/lint.sh\` 乾淨；手把手 \`node build.js journey.md $TEMP/j-check.docx\` 成功；\`run-chapter.js\` 抽出第 17 章 27 塊，bash -n 全過。

## 沒有驗證
見 status-redesign.md 的第一段。
