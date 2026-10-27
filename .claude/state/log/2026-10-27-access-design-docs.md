# 2026-10-27 主機存取設計文件與客戶資訊簡報

## 做了什麼
- 桌面草稿「整理 kafka 客戶資訊.pptx」重新分析，曾產出 16 頁簡報（後來依使用者決定刪除，原始碼也一併刪除；git 歷史還在）。原稿的問題：Staging 硬體表 10 台對架構圖 7 台、附註 0.58 MBps 與 125 萬筆×6 KB 換算的 0.087 MB/s 不符、兩張硬體圖沒標環境、「理論上支援 JDK 25」是推論、PVWA 寫成 PCWA、「ominbus」拼字。磁碟估算每一項已用公式驗算（157.5 → 39.4 → 65.6 → 131.3 GB）。
- 依客戶討論後的做法寫 Word：`docs/Confluent-CyberArk登入與主機存取設計.docx`（來源 `docs/access-src/access.md` + `diagrams.js`，6 張圖，資拓宏宇官網配色與 logo，不含指令只有設定範例、不提 OP menu 與明年採購）。
- `docs/journey-src/build.js` 可帶參數（來源、輸出、diagrams.js），meta 可帶 theme／company／logo；預設行為不變，手把手仍能建置。`diagrams.js` 匯出圖形工具 `_h`。
- Prometheus → Alertmanager mTLS 實測（c3-01 用 curl）：有 cp-server 憑證 200；無憑證、自簽（CN 同為 cp-server）被拒；銀行 CA 簽發的另一張（svc-backup）也 200（沒有 CN 白名單）。

## 決定（細節在 redesign/README.md「和客戶討論後的主機存取做法」）
PSMP 代登 root；一組金鑰放操作機 root 0400；各主機 `cpuser`；sudoers 白名單；私鑰不放 CyberArk、不備份；OP menu 維持 AD 登入；file system 議題不討論。

## 沒做／待做
- Docker 沒開，換金鑰、公鑰佈署、鎖定密碼只靠金鑰的指令沒有在 lab 驗證。
- 簡報第 12、13 頁仍寫 cpadmin；Word 寫 cpuser（簡報是否同步待使用者決定）。
- 手冊、install/、OP menu 還沒改。
