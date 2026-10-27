# 2026-10-28 版本路徑重整：主線 = 安裝基底 → 遷移

使用者 2026-10-27 夜間定案（不再問）：第 1–20 章裝 Confluent 8.2.4＋C3 2.5.1＋JDK 21＋OS 9.6，第 21、26、27 章遷移到 8.3.2＋C3 2.6.1＋JDK 25＋OS 9.8。章號 0–27、站號 01–26 不變；升級演練併進主線。
這一輪由背景 agent 完成，**沒有動 lab**（舊 lab 壞的，之後從零重建）。只用了拋棄式 `lab-mig-*` 容器（已全部刪除，映像 `lab-mig-node:96` 也刪了；`rockylinux/rockylinux:9.6` 映像留著，之後建 lab 要用）。

## 查到的事實（有證據的）

- C3 對照（docs.confluent.io Versions and interoperability，2026-10-28）：2.5.x = CP 7.5.11 以上、7.6.8 以上、到 8.2.x；2.6.x = 7.5.15 以上到 8.3.x；2.4.x 以下只到 8.1.x。Java：CP 8.2.x 支援 17／21（建議 21），8.3.x 支援 17／21／25（建議 21）。→ 基底 C3 = **2.5.1**（2.5.x 最新，2026-06-23），目標 2.6.1（最新）；CP 升 8.3 前 C3 先升（2.6.x 也涵蓋 8.2.x）。
- packages.confluent.io 的 C3 RPM 有 2.0.0–2.6.1 共 15 版，2.5.0／2.5.1／2.6.0／2.6.1 都只相依 bash；`dnf download --url --resolve` 對 8.2.4＋2.5.1、8.3.2＋2.6.1 各解出同樣的 11 個檔（ce-kafka-http-server、cli、common、control-center-next-gen、kafka-rest、metadata-service、rest-utils、security、server、server-rest、telemetry）。8.2、8.3、C3 三個 repo 的 archive.key 相同（sha256 b569e9d8…）。
- C3 2.5.1 與 2.6.1 的 `/etc/confluent-control-center/`（各取 RPM 前 30 MB 的 payload 解開）逐檔比對：只差 `control-center-dev.properties` 多一行 `confluent.controlcenter.docs.host`；2.5.1 的 `prometheus-generated-local.yml` 已有 `otlp`（promote_resource_attributes）與 `storage` 兩段 → 第 13 章設定兩版通用。release notes（2.5.0–2.6.1）沒有 OTLP 設定變更；2.6.1 移除舊的 JavaMail 寄信（我們不用 C3 告警動作）。
- Rocky 9.6 映像的預設 repo 指向最新 9.x（`$releasever`=9，mirrorlist）：裝出來是 9.8 套件，必須改 vault 9.6。vault 9.6 比映像新（glibc el9_6.24 vs .14）。9.8 在 `pub/rocky/9.8`。
- 拋棄式容器數字：9.6 套件集合 71 RPM／20 MB／53–97 秒；9.8 更新集合 152 RPM／78 MB／約 160 秒（148 待更新）；本地 repo `dnf update` 9–11 秒到 9.8；versionlock 的 jq 不動；systemd 容器更新後 running、sshd／chronyd active；`needs-restarting -r` 要重開機（glibc、systemd、dbus-broker）。RPM 簽章都是 `RPM-GPG-KEY-Rocky-9`。
- 容器不能重開機：`systemctl reboot` → `Call to Reboot failed: Could not activate remote peer`；`systemd-detect-virt -c` 回 `wsl`。
- 下載陷阱：`dnf update --downloaddir X` 後又拿 X 當 `file://` repo 更新，RPM 被刪光，只剩 repodata → 先複製再建索引。

## 改了什麼

- 手把手：meta／0.4（版本路徑表與 lab 限制）／0.5（映像 `lab-node:96`＋vault 設定檔、`lab-web:96`、dl01 的 vault repo）／1（兩套下載、兩個 JDK、72 行 SHA256SUMS、C3 版本證據）／2／3.2（9.6 套件庫）／3.3／5／8（基底版本）／10.4 out（4.2-IV1A 預期）／13（C3 2.5.1 註記）／17（指標覆蓋註記）／19／20（註記）／21（改寫：21.1 上架、21.3 C3 先升並建 c3-change.sh、21.10 收尾）／23／26（改名；新增 26.0 套件庫同步、26.5 驗證／限制／回滾／別的小版本；os-reboot.sh）／27（改成單獨換 C3 版本）；rest-restart.sh 在容器上 `-r` 改重啟。
- install：site.env（`CP_VERSION`／`C3_VERSION`／`JDK_MAJOR`／`OS_BASE_VERSION` 與 `*_TARGET_*`）、01（兩套下載、兩個 JDK）、02、03、05、21（publish／adopt／C3 先換／jdk 預設目標／rollback 預設基底）、26（os 版本、verify、容器改重啟）、`templates/rest-restart.sh`、`java.sh` 註解、alerts 註解。
- lab：bank-sim（`NODE_IMAGE`、`os-content`、`os-sync`、`landing-layout`、9.6 套件庫改由 vault 備）、run-customer.sh（整條路 31 段）；刪 `run-upgrade-drill.sh`、`run-all.sh`（冪等驗證併進 `IDEMPOTENCE=1`）。run-full.sh 先 `landing-layout`，保留 landing 與 bank-os。
- 文件：問題清單 2.5／3.4／3.5（已重建 docx）、redesign/README.md 最後一節、README／CLAUDE.md／install/README／tools/README／skills（lab、bank-role）、diagrams.js 三處。

## 落地區對照（舊 → 新；從零重跑時由 `bank-sim.sh landing-layout` 自動搬，不需要手動）

| 舊 | 新 |
|---|---|
| `landing/rpm/`（8.3.2×10＋C3 2.6.1） | `landing/rpm-target/` |
| `landing-extra/rpm/`（8.2.4×10） | `landing/rpm/`（01 站補下載 C3 2.5.1） |
| `landing/bank/` JDK 21.0.13 | 不動 |
| `landing-extra/bank/` JDK 25.0.5 | `landing/bank/`（01 站驗 sha256，不重抓） |
| `landing-extra/bank/` JDK 21.0.12.1 | 用不到，可刪 |
| `landing/c3/`（C3 2.6.0，第 27 章演練） | 不動 |
| `landing/os-packages.txt`、`SHA256SUMS` | 01 站重新產生 |
| `bank-os-repo/`（9.8 為主的舊套件庫） | 作廢；改 `bank-os/{9.6,9.8-updates,9.8}`（`bank-sim.sh os-content` 備） |

## 還沒做／要注意

- 整條路沒有在 lab 實跑：`run-full.sh customer` 與 `run-customer.sh` 都要等 lab 從零重建後跑；手把手各章 `out` 是預期值。第 21 章的實測數字是 2026-10-26 舊演練的（文中已標）；26.5 的持續流量數字寫「尚無實測」。
- 第 17 章 dashboard／指標覆蓋表是 8.3.2／C3 2.6.1 的實測，8.2.4／2.5.1 基底沒重驗（文中已註記）。
- `docs/Confluent-RPM安裝流程.pptx`（銀行主管簡報）沒動，標題仍寫「Confluent Platform 8.3 企業版」；是否要改成 8.2→8.3 路徑留給使用者。
- JDK 21.0.x 與 JDK 25 的實際小版本以 01 站 Adoptium 當下的為準。
