# Status — branch `redesign`

Updated: 2026-10-24 晚（lab 已停、Docker Desktop 已關：使用者要用記憶體）

## 現在在做什麼
安裝流程重新設計（使用者主導、Claude 記錄）＋ `install/` 一章一支的安裝腳本（照手把手文件），以 `lab` 專案實跑驗證。

## 做到哪
- 手把手文件 `docs/Confluent-安裝旅程-手把手.docx`：第 0–21 章（21 = 憑證輪替：leaf 換發＋CA 三階段，lab 實跑），docx 已重建。
- `install/`：steps 01–21 全部寫完並經可讀性整理（完整命名、註解、ssh_script heredoc、只用 bash／CLI，不用 python／node／jq）。
  - 從零驗證到第 20 站：sp 模式 39/39；conjur 模式 38/38；第 21 站（status|leaf|trust-sync，on-demand）在 lab 驗過（leaf 用 G2 簽、trust-sync）。
  - 11 站 role binding 加 `retry 3 5`（滾動重啟後 MDS 暖機）。
  - `install/README.md`「寫法約定」第 3 點被 JS replace 的 $＋反引號 替換符號弄壞過（bcec6ce 裡是壞的），本次已修。
- 定案：客戶 CyberArk 只有代登＋SSH 金鑰輪替（無 CCP/CP/Conjur）→ cpadmin 私鑰人工從 PVWA 貼進 ssh-agent；OP menu 同；MDS token 金鑰**不排輪替、不寫文件**；kafka-internal 維持 7 台共用；憑證輪替 = leaf＋CA 三階段。
- OP menu：manual 來源（要用才取私鑰）、緊急主機模式（14/14）、A/B 服務帳號（34/35/37）、新密碼寫 0600 交接檔（`$HOME/opmenu-handover`，寫不進去就不改密碼）、17 看各端點實際出示的憑證。lab 已裝 `opmenu-20261023.0655fe43`。
- OP menu 全項目回歸（`install/lab/opmenu-items-test.sh`）：**37/37 通過**（第 3 輪的 6 敗是測試腳本 glob 在 cpadmin 展開，改 `sudo sh -c` 後全過）。redesign 第 13 節、opmenu/README 已寫入 A／B 帳號、交接檔、17 看端點。
- `install/tools/lint.sh` 加入（全部乾淨）；sp 模式重跑 10／12／13 自動加密、10 帶稽核設定（lab 39/39，10 台明文 0）。
- 第 10 站重跑：設定有變才一台一台重啟（lab A/B 測試通過、39/39）。手把手文件：每個指令上方自動標「▶ 在哪台（帳號）執行」，換機器時附切換指令（build.js）；「對應腳本」框與 0.6 已移除（使用者：之後另寫一份腳本使用說明）。
- master key：CyberArk 存 passphrase＋master key 兩個 object；install 16 加 VAULT_ACCESS（manual 等 PVWA 保管確認才派送）；手把手 16 章更正（docx 已重建）。

## 下一步
- 使用者同意放棄手打驗證、lab 交給 Claude（2026-10-24）。
- 客戶模式從零（CP 8.2.4）**38/38 通過**（lab 目前就是這套，等著升級演練）。
- **下一步**：之後寫升級章（8.2.4→8.3.2、JDK 21→25 三段、C3 留 21）並實測。
- 腳本使用說明：已併進 `install/README.md`（每站對照表、lab 與客戶設定差異、安裝後的重跑；commit 6df1591）。
- 從未 push。

## 環境狀態
- lab: **已停**（容器 stop、Docker Desktop 關閉、wsl --shutdown）。狀態：驗證 B 跑到 `22-upgrade.sh packages` 中途被中斷（plan、backup 已過），lab 是半升級狀態，下次從零重建即可。重開：啟動 Docker Desktop → `cd ~/kafka-lab && docker compose -f compose.yml start && docker start dl01`。
- 磁碟：`packages-manual.old/`（6 GB）可刪；`delivery/` 可刪。
- 密碼檔：`docker/manual/secrets.env`（AD 三組）；ops02 `~/secrets/`、`~/pki/store.pass`。

## 待辦（2026-10-24 晚，依序）
1. 驗證 B 重跑：客戶模式從零 8.2.4 → `22-upgrade.sh` plan／backup／packages／jdk 25／rollback kb04／ONLY_HOSTS 升回／finalize（不帶確認要停、帶確認升版）→ 驗收。腳本：scratchpad 的 valB.sh（要重寫成 repo 內的 lab 腳本較好）。
2. 全書照文件從零實跑（lab 模式，第 0–21 章，run-chapter.js）：驗證審查修正（d7f4c31）的指令與預期輸出。
3. 補強需要 lab 的：第 6／7 章檔案系統與 java.io.tmpdir、第 10 章 metadata.log.dir、第 18 章 raft 指標（README 說法待更正）、第 19 章稽核 topic RF。
4. 新章：license（讀 JWT 到期、套用程序未實測、告警）、controller 替換（kc03 同名換新機）、broker 縮減／擴充（kb04）。
5. 日常備份章（svc-backup 唯讀身分、排程＋OP menu）、OS 修補、C3 升級（使用者這次沒選先做）。
