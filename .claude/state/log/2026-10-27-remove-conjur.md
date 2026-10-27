# 2026-10-27 刪除 Conjur／provider 模式與 CyberArk 應用面

## 決定（使用者）
客戶完全不用 CyberArk 應用面（Conjur、Summon、Conjur config provider、CCP／CP）。從手把手、install、opmenu 全部刪除，只留客戶模式（CyberArk 只有 PAM：PSMP、PVWA、CPM、SSH Key Manager）。

## 規則
- 只剩 `customer` 一種模式；`conjur`、`provider` 刪除。
- 刪第 15 章（Conjur）、16.8（Summon）、16.9（AD 密碼經 Conjur）與所有 conjur／provider 專用區塊。
- 第 N 章（N≥16）→ N−1：16→15、17→16、18→17、19→18、20→19、21→20、22→21、23→22、24→23、25→24、26→25、27→26、28→27。手把手 0–27 章，install/steps 01–26。Secret Protection 內小節跟著位移（舊 16.10 → 新 15.8）。
- 不是章節編號的數字不動：版本、IP、port、OP menu 項目編號。
- cpadmin 等其他設計不動；cpuser／PSMP 登入 root 的設計變更另案（見 log/2026-10-27-access-design-docs.md）。

## 進行中（三個 agent 並行）
1. 手把手 `docs/journey-src/`：刪章節與選配區塊、改編號、重建 docx。
2. `install/`、`opmenu/`：刪 conjur／provider 腳本與 `lib/vault.sh`、`run-all.sh`／`EXT=1`、`OPMENU_SECRETS=conjur` 後端；步驟改名。
3. 其餘文件：README、CLAUDE.md、問題清單（questions.md）、簡報（deck-src）、redesign/README.md（新增同日定案段落）、skills、memory、本狀態檔。問題清單與兩份簡報已重建。

## 尚未做
- **沒有在 lab 重跑任何東西**（Docker 關閉）。新編號、被改過的指令塊、改名的 install 步驟都未驗證。
- **必做**：從零跑客戶模式——`bash docs/journey-src/tools/run-full.sh customer`、`bash install/lab/run-customer.sh`、`bash install/lab/run-upgrade-drill.sh`，逐行看日誌、`scan-log.sh` 掃；通過後才能說編號驗證過。
- 刪除前的內容在 git 歷史裡（本次刪除 commit 之前）。
