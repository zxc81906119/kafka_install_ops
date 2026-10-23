# Status — branch `redesign`

Updated: 2026-10-23 晚（lint＋重跑自動加密，lab 在跑）

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
- 第 10 站重跑：設定有變才一台一台重啟（lab A/B 測試通過、39/39）。手把手文件加 0.6 與每章「對應腳本」框。

## 下一步
- 本輪任務都完成；等使用者決定下一個題目。從未 push。

## 環境狀態
- lab: `lab` 專案 **在跑**（Secret Protection＋Summon＋16.9 模式；CA 已換成 G2；MDS token 金鑰已換新，ops02 ~/pki 舊的 .old；OP menu 0655fe43）。Conjur 三容器、dl01 也在跑。停：`cd ~/kafka-lab && docker compose -f compose.yml -f conjur.yml stop && docker stop dl01`
  重開：`cd ~/kafka-lab && docker compose -f compose.yml -f conjur.yml start && docker start dl01`
- 磁碟：`packages-manual.old/`（6 GB）可刪；`delivery/` 可刪。
- 密碼檔：`docker/manual/secrets.env`（AD 三組）；ops02 `~/secrets/`、`~/pki/store.pass`。
