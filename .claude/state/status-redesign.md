# Status — branch `redesign`

Updated: 2026-10-30 17:15（lab 沒有在跑的工作；lab 是「重置後」的乾淨叢集，見環境狀態）

## 現在在做什麼
試用 license 到期的處理寫成手冊 **26.4「試用期到期：申請延長，或重置測試環境的叢集」** 並實測兩輪（log/2026-10-30-trial-reset.md）。沒有進行中的工作。

## 今天（10-30）做完
- 手冊從第 0 章完整實跑通過（407 塊；log/2026-10-30-full-manual-run.md）。
- 手冊殘留的 CyberArk 保管說法清掉（f9bcd44）；docs/evidence 不進版控；job label 不改官方檔；銀行沒有 Streams 應用。
- Docker Desktop 後端當掉（socket 檔壞）→ 把 `%LOCALAPPDATA%\Docker\run` 改名（`run.old-20261030`）後恢復。
- 26.4：重置程序第一輪手動實跑、手冊寫好（D.clusterreset 圖在前；8 塊，`@role` 第 4 欄「整本實跑不執行」→ run-chapter.js 略過）、第二輪照手冊原文實跑全過（ACL 4 條建回、第 19 章健康 22/22、安全 16/16、應用程式寫讀過；新試用期到 2026-11-29）。
- 23.3 `acls.txt` 改成一條一行（`TYPE|name|pattern|principal|host|op|perm`，舊格式排序後無法還原）；手冊與 `install/steps/23-metadata-backup.sh` 都改；23.6 `metadata-restore.sh` 加 `set -f`（`Topic:*`）。

## 下一步（候選）
1. 26.4 包成腳本（三步規則的第三步；破壞性，要明確確認才執行）— 還沒做。
2. 腳本版從零再跑一次（10-30 那一輪在第 18 段中斷、已放棄）：驗 exporter 1.7.0（02／17 站）、緊急主機模式不看群組（28-triage）、23 站新 ACL 格式。
3. 待使用者決定：《請銀行確認的事項》要不要加一題 license 涵蓋範圍與試用風險。
- 待銀行回覆：換金鑰週期；omnibus 正式值。

## 環境狀態
- lab：專案 `lab`，由腳本版（中斷於第 18 段）建出，CP 8.2.4（遷移中途）、C3 2.6.1、JDK 21、OS 9.6；之後做過兩次 26.4 重置（新的 cluster id，舊的 kraft.env 另存在 ops02 `~/conf/kraft.env.before-reset-*`）。手冊第 23 章的 `~/conf` 程式與 `cluster-restore-all.sh` 已裝；第 16 章手冊的 `opmenu-try.sh` 沒有（19.4 那一行因此找不到檔）。下一輪從零跑前不需要保留。
- Docker VM 約 10.7 GB，不要同時跑別的。絕不按 Docker Desktop 的 Reset to factory defaults（會清掉 volume `ops-secure`）。
- 密碼檔：`~/kafka-lab/secrets.env`；ops02 `~/secrets/`、`~/pki/store.pass`、私鑰 `/secure/ssh`（volume `ops-secure`）。
- Git Bash 的 `python3` 是 Store 空殼：改檔用 node；跑手冊片段時 `export MSYS_NO_PATHCONV=1`。
