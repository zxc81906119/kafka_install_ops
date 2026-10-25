# Status — branch `redesign`

Updated: 2026-10-25 早上（lab 停止中：Docker Desktop 未啟動）

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
- lab: **使用中（Claude）**：lab 模式照文件從零跑第 0–21 章（第二次，189 塊；第一次在 21.3.4 抓到文件缺陷後已修）。22:24 時 93 塊 rc=0、在 15.3 建 jar，沒有被遮住的失敗。執行檔：scratchpad 的 full.sh（由 journey.md 產生，17.3 佔位路徑換成 repo 路徑），紀錄 scratchpad/full2.log；跑完要掃「a password is required／Permission denied／FAIL／MDS=000／REST=000／驗不過」。落地區的 8.2.4 RPM、JDK 25、舊 JDK 21 暫放 ~/kafka-lab/landing-extra/，演練升級時要搬回。
- 磁碟：`packages-manual.old/`（6 GB）可刪；`delivery/` 可刪。
- 密碼檔：`docker/manual/secrets.env`（AD 三組）；ops02 `~/secrets/`、`~/pki/store.pass`。

## 待辦（2026-10-25 早上；夜間工作的細節見 log/2026-10-25-overnight-chapters.md）
1. ~~全書重跑~~、~~21.4 換鏈＋chain 腳本~~、~~第 23 章 license＋23-license.sh~~、~~第 24 章換 controller＋24-controller-replace.sh~~、~~第 25 章 broker 增減＋25-broker-scale.sh~~、~~第 26 章日常備份＋26-metadata-backup.sh~~、~~補強第 6／10／18／19／22 章~~：全部 lab 實跑通過。
2. **還沒做**：所有演練之後的最後一次第 20 章驗收（20.1–20.3）。跑的時候 session 中斷、Docker Desktop 也停了；開 lab 後先跑這個。
3. lab 其他 5 台（kc02、kc03、kb02–kb04）的 properties 還沒有 `metadata.log.dir`（值等於預設）；下次重新產生設定時帶入。
4. 之後：OS 修補章、C3 升級章；OP menu 44 擴充「立即匯出」備份；遮蔽失敗掃描加 ERROR／登入失敗／login: 401／AUTH_FAIL。
