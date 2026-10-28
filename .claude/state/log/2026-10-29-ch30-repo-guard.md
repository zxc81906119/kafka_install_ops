# 2026-10-29 第 30 章保險：套件庫混到 RHEL 10 內容時要停

- 30.1 每台先比對「套件庫裡 release 套件的主版本」與目前主版本：不一致印 `停：套件庫是 10.x 的內容…` 且不做 `dnf upgrade --assumeno` 預覽；一致印 `主版本一致（9.x → 9.8）`。
- lab 沒有 10 的內容：用 dl01（唯一能連外網）對 Rocky 10 公開倉庫跑同一個判斷（`dnf repoquery --repofrompath`），實測 release 套件 10.2 → 停。手冊 30.1 多一塊 dl01 區塊當證明。
- `30-os-patch.sh plan`：主版本不一致 → FAIL（不進 apply）。實測 11 台都「主版本一致」。
- 問題清單 3.6：套件庫同步能否保證只含 RHEL 9；修補前誰確認 release 套件版本。
