# 2026-10-27（夜）新的主機存取做法進手冊與腳本

依客戶討論後的做法（`docs/access-src/access.md` 是規格，那份 Word 沒有動），把 cpadmin／ssh-agent／SSH Key Manager 全部換掉。**沒有 commit、沒有碰 lab（舊叢集已壞、等人從零重建）；只做靜態檢查與兩個拋棄式容器的小驗證。**

## 改了什麼
- **手冊 journey.md**：第 0 章（映像不再內建 cpadmin／sudoers／共用 `authorized_keys.d`；compose 加 `ops-secure:/secure/ssh`、`ops-home:/root`；進操作機一律 root）、第 2 章、**3.1 整節重寫**（3.1.1 每台建 cpuser、3.1.2 操作機建金鑰與 `~/.ssh/config`、3.1.3 公鑰行 `from=`、3.1.4 驗證、3.1.5 `from=` 擋別台）、第 15 章備註、**第 16 章整章重寫**（金鑰檔、不貼 PVWA、sudoers 逐一列出＋9 種寫法的驗證、誠實的限制）、19.4（冷開機後金鑰還在）、19.5、**19.6 改成手動換金鑰演練（含探針）**、全書 `@role … | ops02 | cpadmin` → root、`/home/cpadmin` → `/root`、`docker exec -u cpadmin` 去掉、ops02 本機的 `sudo` 拿掉（遠端的保留）、systemd timer 去掉 `User=cpadmin`。`diagrams.js`（cast／map／bankprep／opmenu 圖）、`build.js` 的 `ENTER`、`tools/run-chapter.js`、`tools/README.md`。
- **install/**：`lib/ssh.sh`（`-i $SSH_KEY`、`$SSH_USER@`、`ops_from_addrs`、`authorized_keys_line`）、`conf/site.env`（SSH_USER／SSH_USER_ID／SSH_KEY_DIR／SSH_KEY／SSH_KEY_REQUIRE_MOUNT／SSH_FROM_ADDRS；拿掉 SSH_KEY_SOURCE、OPMENU_OS_USER）、03 站（掛載點檢查、建金鑰、`~/.ssh/config`、cpuser 逐台驗證）、16 站（root 跑選單、sudoers 逐一列出）、19 站文字、02／04／20／21／22／25 站本機 sudo、`templates/opmenu.conf`、`lab/bank-sim.sh`（`os_team_cpuser`、`prepare`；移除 `pvwa-key`）、`run-customer.sh`／`run-all.sh`／`run-upgrade-drill.sh`、`opmenu-items-test.sh`、`opmenu-emergency-test.sh`；刪 `opmenu-manual-test.sh`、新增 `opmenu-hostkey-test.sh`；README。
- **opmenu/**：`OPMENU_SSH_KEY_FILE`（預設 `/secure/ssh/cpuser_ed25519`）、`OPMENU_SSH_USER=cpuser`；`_ssh` 帶 `-i`／`IdentitiesOnly`／`IdentityAgent=none`；拿掉 `core_load_ssh_key`／`core_unload_ssh_key`／`core_ssh_key_on_demand`／`core_ensure_ssh_key`／`OPMENU_SSH_KEY_LOAD`／`_TTL`／`_SECRET`（改 `core_check_ssh_key`，缺檔就 BLOCKED）；`lib/secrets/manual.sh` 留著只給 91；`be_service_logs` 固定 `-n 200 --no-pager`（本機 tail）、`be_collect_diag` 逐服務；README；測試 `test-ssh-key.sh` 重寫、新增 `test-sudo-forms.sh`。
- 問題清單（4.2–4.8、8.3、8.4、8.8、9.1、9.3、已知前提、port 表）已重建 docx。README、CLAUDE.md、skills（lab、bank-role、manual-step）、redesign/README.md（舊三段標「已被取代」，新增「新做法已進手冊與腳本」）、status。

## sudoers 逐一列出的寫法與 OP menu 的對照
`/etc/sudoers.d/cpuser-ops`（0440，`visudo -cf`；每台只列自己的服務 U：controller／broker = confluent-server，REST = confluent-kafka-rest，C3 = confluent-control-center）：
1. `/usr/bin/systemctl restart U`
2. `/usr/bin/systemctl status U`
3. `/usr/bin/journalctl -u U -n 200 --no-pager`

| 選單項目 | 送到主機的 sudo | 在清單裡 |
|---|---|---|
| 21、22、27 重啟 | `sudo -n systemctl restart U`（之後的 `systemctl is-active U` 不用 sudo） | 1 |
| 23 看日誌 | `sudo -n journalctl -u U -n 200 --no-pager`，行數在本機 `tail -n N`（N>200 當 200） | 3 |
| 18 收集診斷 | 每台、每個服務一次 `sudo -n journalctl -u U -n 200 --no-pager`（controller 主機只有 confluent-server） | 3 |
| 16 磁碟、22 的 LB 連線檢查 | 不用 sudo（`df`、`ss`） | — |
| 91 緊急模式 | 不碰主機（Kafka 工具） | — |
| 維運人員手動看狀態 | `sudo systemctl status U` | 2 |

`opmenu/tests/test-sudo-forms.sh`（單元）檢查選單送出的每個寫法都在清單裡，且 `_JOURNAL_LINES` 與 `install/steps/16-opmenu.sh` 的 `JOURNAL_LINES` 一致；`install/lab/opmenu-hostkey-test.sh` 在真主機上用臨時帳號 sudotest 套同一份規則驗 3 種放行、9 種拒絕。

## 拋棄式驗證（容器 `tmp-cpuser-test*`，已自動刪除，沒碰 lab）
用 `lab-node:1` 起一個臨時容器（匿名 volume 掛 `/secure/ssh`）：`mountpoint` 成立；cpuser（UID 1500、shadow `!!`）以金鑰登入成功（`localhost`、127.0.0.1、::1 都過）；`sshd -T -C` 回 `no publickey`；密碼驗證被拒；`from=` 改成別的位址就被拒；sudoers 臨時帳號法：restart／status／journalctl -n 200 放行，`-n 5`、`restart … sshd`、`status … sshd`、`restart sshd`、`journalctl -D /etc`、`ls /root` 全拒；19.6 的換金鑰指令（產生 `.new`、取 `from=`、加新行、`-F /dev/null` 測新鑰、成對 mv、依註解刪舊行、舊鑰被拒、每台剩 1 行）全部照預期。**踩到的坑**：在 heredoc 裡的 `ssh` 會吃掉後面的指令（要 `</dev/null`）；`ssh cpuser@<IP>` 不會套用 `Host *.poc.lab` 的 IdentityFile（手冊都用 FQDN）。

## 沒驗證、從零重跑要看
- 容器內 `systemctl reload sshd`（bank-sim／3.1.1）、3.1.5 的 sshd 日誌訊息（journald）、`mountpoint /secure/ssh` 在 compose 的 volume 上、`docker exec -w /root`。
- 16.4 九種寫法的實際輸出、16.5 `opmenu-try.sh`（只剩 91 貼上）、`opmenu-hostkey-test.sh`、`opmenu-emergency-test.sh`（root 加進群組後 `runuser` 重新讀群組）。
- 19.6 探針的失敗次數（預期 0～1，換私鑰瞬間）。
- 手冊 `out` 區塊是照預期寫的，不是實跑結果（`run-full.sh customer` 重跑後逐行對）。
- `docs/Confluent-安裝旅程-手把手.docx` 沒有重建（只建到 `$TEMP`）；要交付時 `cd docs/journey-src && node build.js`。

## 待使用者決定
- repo01 的 `repodeploy`：套件庫是銀行的主機，部署帳號與 cpuser 並存、公鑰放同一行——是否接受，或改成讓 cpuser 負責上架？
- 緊急主機模式的群組開關（把 root 加進 `opmenu-emergency`）是否可接受；或改成別的判斷。
- 換金鑰週期與執行者（問題清單 4.6）。
