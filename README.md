# Confluent Platform 8.3 企業版 — 離線安裝 PoC

以 Docker 容器在 Windows 11 上模擬多台 RHEL 9 主機，驗證一套**離線、腳本化、冪等、可升級**的 Confluent Platform 企業版安裝流程。所有安裝動作都由「操作機」(ops01) 上的 `cpctl` 透過 SSH 執行；換成真實主機時只需修改 `installer/conf/*.env`。

| 元件 | 版本 | 數量 |
|---|---|---|
| Confluent Platform (Confluent Server, KRaft) | 8.3.2（升級演練起點 8.2.4） | controller ×3（動態 quorum）、broker ×4 |
| REST Proxy | 8.3.2 | ×2，前置 Nginx L4 負載平衡 |
| Control Center Next Gen（內建 Prometheus / Alertmanager） | 2.6.1 | ×1 |
| Eclipse Temurin JDK | 21 | 所有 Java 節點 |
| 模擬 AD（Samba AD DC） | Debian 12 | ×1（環境周邊） |

## 架構

```
Windows ──(8082 / 9021)── lb01  Nginx stream (L4 passthrough, source-hash 黏著) ── 唯一可連外的節點 (DMZ)
                             ├─ rest01 / rest02 :8082   REST Proxy (mTLS + RBAC)
                             └─ c3-01 :9021             Control Center (AD 帳密登入)
cpnet (internal, 無外網) ──────────────────────────────────────────────────────────
  ops01   操作機 + 內部 yum/raw repo (:8080)        ad01  AD (LDAPS :636)
  kc01-03 KRaft controller :9093 (mTLS)             kb01-04 broker + MDS :8090
```

### 身分與驗證

| 誰 | 對象 | 方式 | RBAC principal |
|---|---|---|---|
| controller ↔ controller、broker ↔ broker/controller | CONTROLLER / INTERNAL listener | mTLS，**共用內部憑證** `CN=kafka-internal` | `User:kafka-internal`（super user） |
| 應用程式 | Kafka（CLIENT :9095） | SASL_SSL SCRAM-SHA-512 | `User:<app>` |
| 應用程式 | REST Proxy（經 LB） | mTLS，每個 app 一張 client 憑證 | `User:<app>`（REST 以 MDS token 代理身分） |
| 人員 | Kafka CLI（LDAP :9096）、MDS、C3 | AD 帳密（LDAPS） | `Group:<AD 群組>` |
| REST Proxy / C3 本身 | MDS、TOKEN listener :9094 | AD 服務帳號 `svc-rest` / `svc-c3` | 各自獨立 |
| 所有伺服器的 HTTPS / TLS | — | **共用 server 憑證** `CN=cp-server`（SAN 含所有主機與 LB 名稱） | — |

- C3 / REST Proxy → Kafka 走 TOKEN listener（:9094）：單向 TLS，身分由 MDS 簽發的 OAUTHBEARER token 證明（RS256、效期 1 小時，與官方範例一致）。若資安要求伺服器之間一律雙向驗證，可把 `listener.name.token.ssl.client.auth` 改為 `required`，並讓 REST / C3 出示共用的 `cp-server` 憑證；改完需要滾動重啟。
- REST Proxy **只開放給 legacy app**（`conf/apps.env` 中 `APP_CHANNEL=rest`）。principal 對應規則由這份清單自動產生，且不使用 DEFAULT，因此其他憑證（伺服器、super user、一般 app）一律會被拒絕。一般 app 則以 SCRAM 直連 Kafka。
- `impersonation.protected.users` 由 super.users 加上所有 AD 服務帳號自動產生，不需手動維護。
- mTLS principal 依官方限制**不能套用群組授權**，所以每個 app 的 role binding 是由 `conf/apps.env` 逐一產生。
- 機器帳號不登入 C3（官方文件未記載這種用法）。C3 只給人員使用；C3 與 Prometheus、Alertmanager 之間全程 mTLS。

## 目錄

```
windows/        Git Bash：環境控制 poc.sh、外網下載 download-packages.sh、驗證 verify-packages.sh、掃描 hook scan.d/
docker/         模擬主機 image（node / ops / ad / lb）與 compose.yml
packages/       落地區（不進版控）：RPM、GPG key、SHA256SUMS、manifest、驗證報告
installer/      掛載到 ops01:/opt/cp-installer
  bin/cpctl     唯一入口
  conf/         inventory / versions / apps / os-tuning / compat / secrets（secrets 不進版控）
  lib/          框架：core log inventory remote(Facade) render handler(Observer) step(Template Method) …
  lib/node/     送到目標主機執行的冪等原語（ensure::*、svc::*、kafka/ad 輔助）
  lib/install/  安裝 Strategy：rpm（預設、建議）/ tar（版本並存 + symlink）
  lib/repo/     內部 repo Adapter：local（createrepo_c + httpd）
  roles/        角色 Strategy：controller broker rest c3 lb ad
  steps/        安裝流程 00–10
  upgrade/      升級、controller 替換、uninstall
  templates/    設定檔模板（依版本 templates/<major.minor>/，無則 default/）
  tools/        lint.sh（shellcheck + shfmt）、load.sh（演練用持續流量）
```

## 快速開始（Windows 11 + Docker Desktop，Git Bash）

```bash
cp windows/wslconfig.example "$USERPROFILE/.wslconfig"   # 建議 12GB，修改後執行 wsl --shutdown
bash windows/poc.sh secrets                # 產生 installer/conf/secrets.env（只產生缺少的值）
bash windows/poc.sh build                  # 建立模擬主機 image（需外網，只做一次）
bash windows/download-packages.sh          # 外網下載機：dnf download --resolve + GPG 驗證 + manifest
bash windows/verify-packages.sh            # 放行前驗證：sha256、原廠簽章、掃描 hook → report/
bash windows/poc.sh up                     # 啟動 13 台模擬主機
bash windows/poc.sh cpctl repo import      # 落地區 → 內部 repo（先驗證，同名不同內容一律拒絕）
bash windows/poc.sh cpctl install          # 步驟 00–10，可中斷後重跑
bash windows/poc.sh cpctl verify           # 端到端驗證（34 項）
```

瀏覽器開啟 `https://localhost:9021`（C3，需信任 `ops01:/var/lib/cp-installer/pki/ca.pem`），用 `conf/apps.env` 中的 AD 帳號登入（例如 `alice`，密碼為 `HUMAN_DEFAULT_PASSWORD`）。

## 離線軟體引進流程（建議與銀行討論的方案）

```
外網下載機 ─▶ 驗證 / 掃描 ─▶ 安全檔案交換 ─▶ 內部 repo ─▶ 部署機
download-     verify-        （PoC：packages/    cpctl repo     dnf install（gpgcheck=1）
packages.sh   packages.sh     唯讀掛載到 ops01）   import          + versionlock
```

- **RPM 為主**：使用原廠 GPG 簽章，套件自帶 systemd unit，也能接上 RHEL 9 的 Satellite／dnf 維運流程。
- **tar.gz 為替代策略**（`INSTALL_METHOD=tar`，或執行時用 `CPCTL_INSTALL_METHOD=tar` 覆寫）：適合不允許安裝第三方 RPM、或希望多版本並存的環境。

  | 項目 | RPM | tar |
  |---|---|---|
  | 套件來源 | 內部 yum repo（gpgcheck=1） | 內部 raw repo `/raw/tar/`；節點下載後**比對 sha256**，相符才解壓 |
  | 完整性 | 原廠 GPG 簽章 | CP / C3 原廠**沒有提供簽章**，只能依賴下載時記錄的 sha256；Temurin JDK 有比對原廠 checksum |
  | 安裝位置 | `/usr/bin`、`/usr/share/java` | `/opt/confluent/confluent-<版本>/`，`current` symlink 指向目前版本；C3 用 `c3-current`；JDK 在 `/opt/java/current` |
  | 服務帳號、systemd unit | RPM 自動建立 | cpctl 建立：帳號名稱、unit 名稱、路徑都和 RPM 版相同，所以 drop-in、角色、升級流程共用 |
  | 升級 / 回滾 | `dnf install` / `dnf downgrade` | 解壓新版到另一個目錄 → 切換 `current`；回滾就是把 symlink 切回舊版 |
  | 防止誤升級 | `dnf versionlock` | 不受 OS 套件管理影響；切換版本只能透過 `cpctl upgrade` |
  | C3 前置套件 | yum | 仍從內部 OS 相依 repo 安裝（cyrus-sasl、openssl-devel） |

  **tar 策略實測結果**（2026-10-14）：
  - 安裝 8.2.4：34/34 驗證通過；以 `install --force` 重跑一次，結果 **changed=0**。
  - 演練順序：8.2.4 → 8.3.2 → 回滾 8.2.4 → 8.3.2 → finalize。全程有持續流量，SCRAM 寫入 5,320 筆、**0 筆遺失**，REST 0 失敗。
  - 回滾約 3.5 分鐘（RPM 的 `dnf downgrade` 約 8 分鐘），因為舊版目錄還在，只要切換 symlink 再重啟。
  - **磁碟規劃**：
    - 每個版本目錄約 1.6–1.8GB，多個版本會並存。
    - 下載的壓縮檔快取在 `/var/cache/cp-installer`，每台約 2.7GB。
    - 正式環境請預留空間，或在 finalize 之後手動清除舊版目錄與快取。
- **內部 repo 的實作可替換**：安裝只依賴標準 yum `baseurl`。行內若有 Satellite、Artifactory 或 Nexus，只要換掉 `lib/repo/` 的匯入 adapter 並修改 `REPO_*_BASEURL`。若行內沒有任何制品庫，就用 `local`，由操作機自己提供 repo。
- **舊版本一律保留**：`dnf downgrade` 回滾需要舊版套件，而且 Confluent 會把 EOL 版本從官方 repo 移除。
- **稽核軌跡**：每次匯入都把 `SHA256SUMS`、`manifest-rpm.json`、驗證報告保存在 `/srv/repo/manifests/<時間>/`。

## cpctl 指令

| 指令 | 說明 |
|---|---|
| `cpctl install [--from NN]` | 依序執行步驟 00–10；失敗修正後可從失敗的步驟續跑 |
| `cpctl step NN_name` | 只執行單一步驟 |
| `cpctl install --check --diff` | 乾跑：列出會變更的項目與設定差異（密碼遮罩），不做任何變更 |
| `cpctl verify` / `cpctl status` | 端到端驗證 / 各步驟最後成功時間與服務狀態 |
| `cpctl upgrade plan\|backup\|stage\|rolling\|finalize\|rollback --to <ver>` | 滾動升級（見下方 SOP） |
| `cpctl controller replace --old kc03 --host kc04` | 動態 quorum 成員替換 |
| `cpctl uninstall --yes-really` | 移除套件、設定與資料；保留內部 repo、PKI、AD 帳號 |

步驟：`00 precheck` → `01 os_baseline` → `02 distribute`（RPM）→ `03 pki` → `04 ad_bootstrap` → `05 configure` → `06 kraft_format`（`--initial-controllers` 動態 quorum）→ `07 start_core` → `08 security_bootstrap`（SCRAM、RBAC、topic）→ `09 start_edge`（REST、C3、LB）→ `10 verify`。

### 冪等性

- 所有變更都經過 `ensure::*`：先比較目前狀態，一致就報 `ok`，不一致才動作並報 `changed`（設定檔以 sha256 比對，覆蓋前保留 `.bak.<時間>`）。
- 設定有變時只通知 handler，之後逐台重啟並通過健康檢查（health gate）才處理下一台。待重啟清單保存在 `state/handlers.pending`，中斷後不會遺失。
- 驗收結果：在已安裝的環境再跑一次 `cpctl install --force` 得到 **changed=0**（562 ok，含 34 項 verify）。

## 升級 SOP（依 CP 8.3 官方文件：broker 先、controller 後）

```bash
cpctl upgrade plan     --to 8.3.2   # 檢查升級路徑、C3/JDK 相容性、repo 是否已有目標版本、禁用設定、叢集健康、憑證效期
cpctl upgrade backup   --to 8.3.2   # 備份 /etc/confluent、systemd drop-in、topic/ACL/SCRAM/feature 清單、RBAC 綁定
cpctl upgrade stage    --to 8.3.2   # 以新版模板產生設定並顯示差異（不變更）
cpctl upgrade rolling  --to 8.3.2   # broker 逐台 → controller（follower 先、leader 最後）→ REST（先從 LB 排空）
cpctl upgrade rollback --to 8.2.4   # finalize 之前都可回滾（dnf downgrade）
cpctl upgrade finalize --to 8.3.2   # kafka-features upgrade --release-version，之後不可回滾，需輸入 cluster id 確認
```

## 從 PoC 移到正式環境的差異

| 項目 | PoC | 正式環境 |
|---|---|---|
| sudo | cpadmin 擁有完整 NOPASSWD sudo | 依 `conf/sudoers.d/cpadmin.restricted` 由資安審核後收斂 |
| AD | Samba 模擬，由 cpctl 建立帳號 | `PROFILE=prod`：由 AD 團隊依申請單建立，cpctl 只檢查 |
| 憑證 | 自建 CA（RSA 3072，效期 1 年） | 改用行內 CA 簽發，放進 `state/pki` |
| heap / retention | `PROFILE=poc` 數值 | `PROFILE=prod`（官方建議值） |
| 核心參數 | vm.* 等只能在 WSL2 主機設定（腳本會警告） | 腳本直接寫入 `/etc/sysctl.d` |
| 內部 repo 傳輸 | HTTP（RPM 有 gpgcheck，其餘檔案有 sha256） | 建議改用 HTTPS |
| License | 未設定，以評估模式執行 | 放入 `conf/license.txt` |

## 已知限制與風險

- `kafka-internal` 憑證由所有 controller 和 broker 共用，而且是 super user：任何一台的私鑰外洩，等於整個叢集被取得。緩解方式：私鑰權限 0640、定期輪替；正式環境也可以改成每台各自一張憑證。
- svc-cpctl 是安裝用的 bootstrap 帳號，列在 `super.users` 中；安裝完成後建議停用，需要時再由 break-glass 程序啟用。
- 在 Docker Desktop 上，從 Windows 發出的請求來源 IP 都相同，LB 的 source-hash 黏著會把它們全部送到同一台 REST Proxy；負載分散要從 cpnet 內的不同來源驗證。
