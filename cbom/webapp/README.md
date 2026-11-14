# web app 的密碼學資產盤點（lab）

把一個自己開發的 web app 放進 Jenkins 的 pipeline 盤點密碼學資產：建置時、部署物（容器映像）、執行期三段，合併成一份 CBOM，用 OPA 判斷，產出報告。對象是典範 app `cbom/app`（Spring Boot，刻意把好的與不好的密碼學用法放在一起；標準答案 `cbom/app/expected-inventory.json` 49 項，這條 pipeline 找到 45 項；每次建置自動對一次答案，結果在 `out/inventory-check.txt`）。

**和 Kafka lab、Confluent Platform 的盤點（手冊第 33 章）沒有關係**：自己的容器、網路、資料夾、port，不需要 Kafka lab 在跑。手冊裡沒有這一塊（2026-11-12 起）。兩邊只共用程式：`cbom-tools.jar`、規則 `cbom/policy/cbom.rego`、`cbom/cbom-report.sh`。

## 檔案

| 檔案 | 用途 |
|---|---|
| `lab.sh` | 建立與收掉 lab 環境（一台 Jenkins，工作 `cbom-webapp`） |
| `webapp-collect.sh` | 收原料：`init`、`build`、`source`、`files`、`image`、`runtime`、`finish`，或 `all` 一次做完 |
| `Jenkinsfile` | 工作 `cbom-webapp`：分階段叫 `webapp-collect.sh`，後半段叫 `cbom-report.sh` |

## 啟動

先決條件：podman 的 machine 在跑；`cbom/dist/` 已經建好（`bash cbom/build.sh`，在一個臨時容器裡建，不需要 Kafka lab；建一次就好）。

```bash
bash cbom/webapp/lab.sh up
```

第一次約 5 分鐘。它會做四件事：

1. 下載 OPA 1.22.3 與 testssl.sh 3.2.5 到 `~/cbom-lab/tools`，各自核對 sha256（已經有就不重抓）。
2. 把工具、規則、收集腳本、`cbom/app` 的原始碼放到 `~/cbom-lab/jenkins/cbom`（掛進容器的 `/opt/cbom`），產生管理員密碼檔。
3. 建映像 `cbom-jenkins:1`：官方 Jenkins LTS 加 plugin、`podman`（當用戶端，連主機的引擎）、testssl.sh 要用的兩個小工具。
4. 啟動容器 `cbom-jenkins`（網路 `cbomnet`），自動建立管理員與工作 `cbom-webapp`。

| 項目 | 值 |
|---|---|
| 網址 | http://localhost:18089/job/cbom-webapp/ |
| 帳號 | `admin` |
| 密碼 | 在 `~/cbom-lab/jenkins/secrets/admin.pass`（`cat` 那個檔） |

改了 `cbom/app`、收集腳本、規則或重建了 `cbom/dist` 之後，再跑一次 `lab.sh up` 就會換成新的（執行紀錄會清掉）。

## 執行工作

在 Jenkins 的工作頁按「帶參數建置」（第一次是「Build Now」，跑過一次才有參數）：

| 參數 | 預設 | 意思 |
|---|---|---|
| `GIT_URL`、`GIT_BRANCH` | 空、`main` | web app 的 git；留空就用掛進去的 `/opt/cbom/webapp-src`（lab） |
| `RUNTIME_EVIDENCE` | 不勾 | 做不做執行期那段：把 app 用映像跑起來，TLS 掃描＋JFR（多 1–2 分鐘） |
| `GATE` | 勾 | 有違規就讓這次執行失敗 |
| `SPEC_VERSION` | 1.7 | CBOM 的 CycloneDX 版本 |
| `CBOMKIT_URL` | 空 | 有填才把只含密碼學資產的 CBOM 上傳到 CBOMkit 供瀏覽 |

這個 app 刻意放了違規的用法，所以關卡開著時結果是**失敗**（紅色），這是關卡該有的行為；關掉關卡是黃色（只標示）。每次執行左邊有「CBOM 合規報告」，上方可以下載 `cbom.json`、`findings.json`、`report.html`。每次執行另外有 `inventory-check.txt`：拿這次的結果對 `cbom/app/expected-inventory.json`，列出沒找到與等級不符的項目（只是量測，不影響這次執行的結果）。

不用 Jenkins、在容器裡手動做也可以：

```bash
MSYS_NO_PATHCONV=1 podman exec -it cbom-jenkins bash
```

```bash
bash /opt/cbom/webapp/webapp-collect.sh all --runtime --src /opt/cbom/webapp-src --raw ~/raw
```

```bash
bash /opt/cbom/bin/cbom-report.sh all --raw ~/raw --out ~/out
```

## 和 CBOMkit 一起開

```bash
bash cbom/cbomkit-demo/demo.sh up --jenkins
```

會啟動 CBOMkit，並把這台 Jenkins 接上 CBOMkit 的網路。工作的 `CBOMKIT_URL` 填 `http://demo-builtin-api:8081`（內建檢查）或 `http://demo-opa-api:8081`（OPA 檢查）：這是從 Jenkins 容器裡看到的位址，不是瀏覽器用的 28084／28086。上傳後在 CBOMkit 的網頁上找專案 `crypto-lab-webapp`。

照著做的完整步驟（含每一步的畫面）：`docs/Cbom-Demo手冊.docx`。

## 收掉

```bash
bash cbom/webapp/lab.sh down
```

加 `--purge` 連映像、Maven 的 volume、網路一起刪。`~/cbom-lab` 的檔案都會留著。

## 要知道的事

- Jenkins 掛了主機的 podman socket，等於能指揮主機上所有的容器。lab 可以這樣做；正式環境的 agent 要有自己的容器引擎。
- lab 只有一個節點（controller 自己），沒有用獨立的 agent 測過。
- `git clone --depth 1` 不能用在只提供靜態檔的 git（例如 `cbomkit-demo` 的 `demo-git`）；`GIT_URL` 要指到一般的 git 伺服器。
- 都看不到的：不經過 JDK 密碼學 API 的純 Java 實作（bcrypt、Argon2）、「沒有演算法」的弱點（JWT 的 `alg=none`）。
- 記憶體：Jenkins 2.2 GB，原始碼掃描的容器最多 3 GB。和 Kafka lab 同時開會不夠（WSL 一共 11 GB）。
