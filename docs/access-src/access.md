<!--meta
{
  "kicker": "CyberArk 整合設計",
  "title": "CyberArk 登入與主機存取設計",
  "subtitle": "人員如何經 CyberArk 進入操作機，再以一組 SSH 金鑰連到各主機，以及金鑰與 sudo 權限如何管理",
  "author": "資拓宏宇國際股份有限公司",
  "header": "資拓宏宇 — CyberArk 登入與主機存取設計",
  "facts": [
    [
      "出具單位",
      "資拓宏宇國際股份有限公司"
    ],
    [
      "讀者",
      "銀行 Secrets、資安、OS 團隊"
    ],
    [
      "範圍",
      "PSMP 代登、SSH 金鑰、sudoers 白名單"
    ],
    [
      "前提",
      "有 PAM（PVWA、PSMP、CPM）；沒有 CP、CCP、Conjur"
    ]
  ],
  "company": "資拓宏宇國際股份有限公司",
  "logo": "assets/logo.png",
  "theme": {
    "colors": {
      "accent": "0C3486",
      "brand": "046BD2",
      "ink": "1E293B",
      "muted": "64748B",
      "headBg": "0C3486",
      "headInk": "FFFFFF",
      "noteBg": "F0F5FA",
      "noteBar": "046BD2",
      "codeBg": "F0F5FA",
      "codeBorder": "D1D5DB"
    }
  }
}
-->
本文件說明維運與安裝人員如何經 CyberArk 進入操作機，再以一組 SSH 金鑰連到各主機，以及金鑰與 sudo 權限如何管理。讀者是銀行 Secrets 與資安團隊。

[[toc]]

## 1. 目的與前提

這份設計把「人是誰」和「連到主機用什麼」分開：人員的身分一律是 AD 帳號，進入操作機之後，連各主機用同一組 SSH 金鑰，不輸入密碼。

| 項目 | 現況 |
|---|---|
| CyberArk | 有 PAM（PVWA、PSMP、CPM）；沒有 CP、CCP、Conjur |
| 人員身分 | AD 帳號，CyberArk 已綁 AD，並已套用 MFA |
| 登入點 | 操作機（人員先登入 CyberArk 的 PVWA 網頁，由 PSMP 代登進入） |

### 1.1 安裝與維運 user：每台主機都是 cpuser

每台主機（含操作機自己）都建立同名的本機帳號 `cpuser`，作為安裝與維運的唯一 user。

| 項目 | 做法 |
|---|---|
| 帳號類型 | 本機帳號，不是 AD 帳號；由 OS 團隊在主機開通時建立 |
| 登入方式 | 不設密碼（鎖定），只能用 SSH 金鑰；sshd 對 cpuser 關閉密碼驗證 |
| UID／家目錄 | 每台建議使用相同的 UID、GID，家目錄 `/home/cpuser`，檔案在主機間複製時擁有者一致 |

好處：

- **一個名稱到處通用**：`ssh` 設定、`authorized_keys`、sudoers、安裝腳本都只處理一個 user，不用依主機角色分別設定。
- **不佔用人員身分**：人員永遠是 AD 帳號，連主機的不是人，是操作機用金鑰代表的 `cpuser`。

**防護**：

| 威脅 | 防護 | 見 |
|---|---|---|
| 私鑰被複製到別處使用 | 公鑰加 `from=`，只有操作機能使用這把金鑰 | 4.3 |
| 私鑰被讀取 | 只放在操作機，root 0400；人員只能經 CyberArk 代登進入 | 4.1 |
| 磁碟、快照或備份被取走 | 私鑰放在獨立加密的 file system，並排除在備份之外 | 4.2 |
| 登入後執行不該做的事 | sudoers 白名單；交付後只剩重啟、查看 confluent 服務狀態與日誌的窄規則 | 6 |
| 金鑰長期不換 | 定期人工換金鑰，新舊並存、不中斷 | 5 |

命名：`cpuser` 與 Confluent RPM 建立的服務帳號（`cp-kafka`、`cp-kafka-rest` 這一類）不衝突。

## 2. 整體流程

![overview]

## 3. 登入流程

![lanes]

| 步驟 | 誰做 | 說明 |
|---|---|---|
| 1–2 | 人員、CyberArk | 人員用瀏覽器登入 PVWA 網頁，輸入自己的 AD 帳密；CyberArk 向 AD 驗證，並做 MFA（客戶已套用） |
| 3 | 人員 | 在 PVWA 網頁上選目標（操作機的目標帳號），按連線 |
| 4 | CyberArk | 依 PVWA 的權限設定，確認這個人能不能連操作機的目標帳號，並取出該帳號的憑證 |
| 5 | PSMP | 代登進操作機，連線全程錄影 |
| 6 | 操作機 | 登入後是 root；人員不需要知道 root 的密碼 |
| 7–8 | 操作機、各主機 | root 用私鑰連各主機，主機用公鑰驗證通過 |
| 9 | 各主機 | sudo 只能執行白名單內的指令 |

追溯依據：**誰在什麼時間進入了 root**，由 CyberArk 的登入紀錄與 PSMP 錄影保存；主機上看到的是 cpuser 的操作紀錄。

## 4. SSH 金鑰：建立與佈署

![keydeploy]

### 4.1 在操作機建立金鑰對

由 root 在操作機建立一組 ed25519 金鑰對。

| 項目 | 做法 |
|---|---|
| 演算法 | ed25519 |
| passphrase | 不設（登入不需要人工輸入） |
| 私鑰 | 放在獨立的 file system（見 4.2），擁有者與群組都是 root，權限 0400；所在目錄權限 0700 |
| 金鑰註解 | 帶建立日期（例如 `cpuser-ops-20261027`），換金鑰時用來辨識新舊兩把 |

檢查：私鑰擁有者是 root、權限是 0400，並且只有 root 讀得到。

### 4.2 私鑰存放位置：獨立的 file system

私鑰放在操作機上一個**獨立的 file system**，不放在系統碟的 `/root` 底下。

| 項目 | 做法 |
|---|---|
| 目的 | 磁碟、VM 快照或備份被取走時，私鑰不會跟著被讀出來 |
| 掛載點 | 例如 `/secure/ssh`，擁有者 root、權限 0700 |
| 加密 | 該 file system 使用加密（例如 LUKS） |
| 備份 | 備份與快照排除這個掛載點；若無法排除，備份內容也要加密 |
| 格式 | 要支援 POSIX 權限（xfs、ext4）；NFS、CIFS、vfat 常被 ssh 以「權限太開放」拒絕 |
| 開機掛載 | 開機時掛載並解鎖（自動或人工輸入，依貴單位規範）；沒掛載成功時 ssh 連不上各主機，需要有處理流程 |

私鑰檔放在掛載點底下（例如 `/secure/ssh/cpuser_ed25519`），ssh 連線時指定這把私鑰。金鑰產生、公鑰佈署與換金鑰的做法都不變。

### 4.3 佈署公鑰

公鑰（`.pub`）由 OS 團隊依變更單放進每台主機 cpuser 的 `authorized_keys`，包含操作機自己。公鑰前面建議加上來源限制：

| 選項 | 作用 |
|---|---|
| `from=` | 只有指定的來源位址（操作機 IP）能使用這把金鑰；建議寫 IP，不寫主機名稱，避免 DNS 異常誤擋 |

範例（cpuser 的 `authorized_keys` 中的一行；整行不換行，多個來源用逗號分隔、不加空格）：

```
from="10.20.1.10,127.0.0.1,::1" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA…（金鑰內容） cpuser-ops-20261027
```

操作機連自己時，sshd 看到的來源位址可能是操作機本身的 IP、127.0.0.1，或 ::1（用 localhost 連線時 ssh 會先走 IPv6），三者都要列入允許來源。

驗證：

- 從操作機對每台主機以非互動方式登入，都成功且身分是 cpuser。
- 從其他主機用同一把私鑰連線，應被拒絕；被連主機的 sshd 日誌會記下「不是來自允許的主機」。

## 5. 換金鑰（人工、不中斷）

![rotate]

做法是「新舊並存」：先讓各主機同時認得新舊公鑰，確認新金鑰能登入每一台，再換掉私鑰、刪掉舊公鑰。每個時間點操作機上都有一把能用的私鑰。

| 步驟 | 動作 | 此時的狀態 |
|---|---|---|
| 1 | 在操作機產生新金鑰對，註解帶新日期 | 私鑰：舊；各主機公鑰：舊 |
| 2 | 用舊金鑰把新公鑰加進每一台，舊公鑰保留 | 私鑰：舊；各主機公鑰：舊＋新 |
| 3 | 逐台用新金鑰測試登入 | 全部通過才進行下一步 |
| 4 | 操作機的私鑰換成新的 | 私鑰：新；各主機公鑰：舊＋新 |
| 5 | 用新金鑰把各主機上的舊公鑰刪除（依註解辨識），並刪除操作機上的舊私鑰 | 私鑰：新；各主機公鑰：新 |

換金鑰期間（步驟 2 到 4），各主機 `authorized_keys` 內同時有新舊兩行，格式同 4.3 節，以註解的日期區分；步驟 5 完成後只留新的那一行。

步驟 4 換私鑰時，私鑰與公鑰檔要成對更換；兩個檔案換完之前，ssh 會發現兩者不成對而連線失敗（實測約為微秒級的空窗），所以請在沒有其他連線作業時進行。

> 新增公鑰時，`from=` 要和原本的公鑰行一致。實際執行前，先在一台非正式主機演練。

操作機重建時，重新產生金鑰對，由 OS 團隊依 4.3 節重新佈署公鑰。

## 6. sudoers 指令白名單

![sudoers]

| 時期 | 檔案 | 誰管 |
|---|---|---|
| 安裝與升級期（全權） | `/etc/sudoers.d/cpuser` | OS 團隊，依變更單開、完成後移除 |
| 交付後（只能重啟、查看 confluent 服務的狀態與日誌） | `/etc/sudoers.d/cpuser-ops`（0440） | OS 團隊 |

範例：

安裝與升級期（`/etc/sudoers.d/cpuser`）：

```
cpuser ALL=(ALL) NOPASSWD: ALL
```

交付後（`/etc/sudoers.d/cpuser-ops`），逐一列出實際的服務與動作：

```
cpuser ALL=(root) NOPASSWD: /usr/bin/systemctl restart confluent-server, \
                            /usr/bin/systemctl restart confluent-kafka-rest, \
                            /usr/bin/systemctl restart confluent-control-center, \
                            /usr/bin/systemctl status confluent-server, \
                            /usr/bin/systemctl status confluent-kafka-rest, \
                            /usr/bin/systemctl status confluent-control-center, \
                            /usr/bin/journalctl -u confluent-server, \
                            /usr/bin/journalctl -u confluent-kafka-rest, \
                            /usr/bin/journalctl -u confluent-control-center
```

controller 與 broker 主機只列自己有的服務。規則檔寫入後，權限要是 0440；要做語法檢查，並確認 cpuser 實際可執行的清單與預期一致。

規則比對的是完整的參數：只有列出的寫法會放行，多帶任何參數（例如 `-n 100`、`--no-pager`）都會被拒絕。日常會用到的寫法要逐一列入。

> **萬用字元要小心。** sudoers 規則中的萬用字元會比對包含空格的任意字串，所以「重啟 confluent-*」也會連同其他 unit（例如 sshd）一起放行。要收緊的話，改成逐一列出實際的 unit 名稱（例如 `confluent-server`、`confluent-kafka-rest`、`confluent-control-center`），不要用萬用字元。

## 7. 檔案位置一覽

![files]
