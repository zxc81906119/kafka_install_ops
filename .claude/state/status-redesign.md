# Status — branch `redesign`

Updated: 2026-10-23 上午（session 收尾，lab 已 stop）

## 現在在做什麼
安裝流程重新設計：由使用者主導逐項討論，Claude 記錄；同時用 cp-man lab 手動（不用 cpctl）走完整個安裝，
並把走過的路寫成給新人的手把手文件。

## 做到哪
- 手動安裝：第 1–19 項完成（下載 → 驗證 → 進內網 → 銀行準備 → 上架 → JDK → 檢查 → OS 調校 → 套件 →
  憑證 → controller/broker → 帳號權限 → REST Proxy → C3），全部驗證通過。第 20 項 OP 選單不納入。
- 第 21 驗收、第 22 收尾：未做。延後：Secret Protection、audit log 路由、JMX exporter。
- 文件：`docs/Confluent-安裝旅程-手把手.docx`：第 0–20 章全部從零實跑通過（15–19 延伸站，20 驗收與收尾），docx 已重建。
  已自檢一輪（名詞小抄、排錯表、重來指引已補）；第 0–14 章已全部從零實跑通過（2026-10-22），預期輸出已同步。
- CyberArk 整合設計討論完成（見 log 2026-10-21-cyberark）；兩份給客戶／原廠的問題已整理。
- `CLAUDE.md` 與 `.claude/skills/*` 已建立；`.claude/state/` 交接機制剛建立。

## 下一步（2026-10-22 使用者定案順序）
1. （已完成）audit log 路由 ＋ JMX exporter → journey 第 18、19 站。
2. （已完成）驗收清單＋收尾 → journey 第 20 站。
3. **已完成（2026-10-23）**：`install/` 延伸站 15–20 寫完並經可讀性整理（完整命名、註解、heredoc、不用 python／node）。**從零驗證到第 20 站通過**（down -v → 01–14 → bank-sim conjur/sp/opmenu → 15（sp 模式略過）–19 → 行內 Prometheus 9/9 → 冷開機 → 20 驗收 39/39）。待辦：SECRETS_MODE=conjur 單獨驗 15；MDS token 金鑰輪替的 lab 實驗（公鑰檔可否放兩把、混合期影響）；客戶無 CCP 的人工模式已接上（SSH_KEY_SOURCE=agent、OPMENU_SECRETS=manual），lab 未實測互動貼上。
4. 每個里程碑 commit（已養成）；從未 push。

## 環境狀態
- lab: `lab` 專案 **在跑**（本 session）：第 16 章＋16.9 狀態、Conjur 三容器在跑、dl01 在跑；正在跑 install/ 延伸站煙霧測試。
- 磁碟：`packages-manual.old/`（6 GB）可刪；`delivery/` 可刪。
- 密碼檔：`docker/manual/secrets.env`（AD 三組）；ops02 `~/secrets/`、`~/pki/store.pass`。
