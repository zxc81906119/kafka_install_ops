# 2026-10-23 — 安裝腳本重寫（install/）

- 使用者定案（單選題）：涵蓋核心第 1–13 章；新建 `install/`，`installer/`（cpctl）保留做對照；驗證＝lab `down -v` 從零只靠新腳本裝起來。
- 設計：一章一支 `steps/NN-<章名>.sh`（01 在下載機跑，02–14 在操作機 cpadmin 跑）；共用只有 `lib/ssh.sh`（rsh/rcp/each）、`lib/render.sh`（envsubst 指定變數）、`lib/log.sh`（log/ok/fail/bank/pending/finish）；
  站點設定單一檔 `conf/site.env`；範本 `templates/*.tpl` 直接取自手把手第 10、12、13 章；銀行步驟用 `bank` 印「請銀行做」再驗證，沒做完 rc 2，`install.sh` 停下提示重跑。
- lab 專用：`install/lab/bank-sim.sh`（Windows Git Bash 扮演銀行：2.2 交換、3.x 準備、9.2 簽發）與 `install/lab/run-all.sh`（從零到第 14 章的全自動驗證）。
- 從零驗證通過（`install/lab/run-all.sh`，lab `down -v` 起算 24 分鐘，0 FAIL／0 WARN）：01 在 dl01（檔案已在落地區，dnf SKIPPED）→ 02–03 停等銀行（rc 2）→ bank-sim prepare → 03–09 停等銀行 → bank-sim sign → 09–14 全 ok：
  quorum leader 1、4 observer、MDS 4×200、alice SystemAdmin／carol DeveloperRead、REST 200/401/000、LB 200、C3 UI 50 秒、Prometheus 124 種指標。
- 寫腳本時修掉的坑：step 11 的 `| while read` 子 shell 會把 fail 計數丟掉（改 `done < <(…)`）；step 05 用 sudo install 放 /tmp/java.sh 後 cpadmin 刪不掉；step 08 versionlock 計數比對取錯欄位；render 檢查 `${…}` 的 regex 漏了含數字的變數名（C3_FQDN）。
