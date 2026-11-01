# 2026-11-01 手動測試 Podman Desktop 的 docker-compose（v5.6.1）

- 測法：lab 的平台狀態在容器裡，不能 down；另建拋棄式專案 `cptest`（scratchpad/cptest/compose.yml），照 lab 的寫法：YAML anchor＋merge key、privileged＋cgroup host（systemd）、tmpfs、ulimits、stop_signal、extra_hosts、internal 網段＋固定 IP、兩個網段、named volume、對外 port、restart unless-stopped。網段 172.39／172.40，image 用本機 lab-node:96。
- 第一次 `up -d` 失敗：`failed to connect to the docker API at npipe:////./pipe/podman-kafka-lab`。podman 本身正常（走 ssh），docker API 的 named pipe 不在、win-sshproxy 沒在跑。
- 原因（Application 事件記錄）：win-sshproxy 要另外 bind `%LOCALAPPDATA%\Temp\podman\kafka-lab-api.sock`，`Only one usage of each socket address` → 整個 proxy 結束、pipe 跟著消失。那個檔是 10-31 22:59:51 的孤兒 AF_UNIX socket（Docker Desktop 反安裝時 WSL 被強制關掉）。從 08:16 起每次開 machine 都這樣（使用者那邊重開也一樣，不是工具的問題）。
- 修：刪掉 kafka-lab-api.sock（Git Bash rm 就刪得掉），podman machine stop/start → `API forwarding listening on: npipe:////./pipe/docker_engine`、win-sshproxy 在跑。
- 重跑 cptest 全過：up -d、ps、systemd running、ulimit 128000、TZ、兩個網段的固定 IP、extra_hosts 名稱＋內網互通、internal 連不出去（000）、volume 可寫、restart unless-stopped、SIGRTMIN+3、Windows localhost:18999 → n1:8080、compose stop/start 保留同一個容器、down -v 後容器／網路／volume 都 0。lab 15 台不受影響，`podman compose -p lab ps` 看得到 14 台。
- `hostname -f` 只回短名：和舊版 v5.5.1 建的 lab 一樣（Podman 不套用 domainname，FQDN 靠 extra_hosts），不是 v5.6.1 的問題；腳本沒用 hostname -f。
- 沒測到：真的對 lab 做 `down -v`／`up -d`（會清掉平台），留到腳本版從零實跑（bank-sim reset）。
- 記錄：CLAUDE.md gotcha、手冊 0.0 加一條陷阱。
- 原因更正（實測）：正常 `podman machine stop` → socket 檔被清掉、下次 start 正常；直接砍 win-sshproxy（等同 machine 還在跑就關 Windows）→ 檔留下、下次 start 出現 `API forwarding … not available`。今早的孤兒檔多半是昨晚直接關機留下的，不一定是 Docker 反安裝。PowerShell Remove-Item 刪得掉。手冊 0.0、CLAUDE.md 已更正：關機前先 podman machine stop。
- 保險（使用者同意）：~/kafka-lab/start-lab.ps1（ASCII；沒有 win-sshproxy 就刪孤兒 socket，machine 在跑但沒轉發就先 stop，再 start；log 在 start-lab.log）。schtasks ONLOGON 要系統管理員（Access is denied），改放使用者啟動資料夾的捷徑「kafka-lab podman machine.lnk」（Startup）。實測：正常狀態什麼都不做；砍掉 win-sshproxy 後執行 → 刪檔、stop、start、API forwarding ok；之後 15 台、compose 看得到 14 台。不要了就刪那個捷徑。這不在手冊裡（lab 個人環境的保險）。
- 使用者決定（11-01）：Podman CLI 也由 Podman Desktop 的引導安裝（手冊 0.0 第 1 步改寫，官方 MSI 留作替代；引導裝 CLI 這條路尚未在乾淨電腦實測）；machine 照 0.0 指令建。自動開機很佔資源，手冊不強調（只寫要用時 start、用完 stop）。start-lab.ps1 與啟動資料夾捷徑保留；Podman Desktop 的自動開 machine 要關（今早 08:16 是它開的 machine），由使用者在 Settings → Preferences 關，之後讀 settings.json 確認。
- 11-01：使用者不要自動開 machine，啟動資料夾捷徑已刪；start-lab.ps1 留作手動修復工具。Podman Desktop engine autostart=false（settings.json 確認）；Podman Desktop 裝了兩份（Program Files 與 LocalAppData），待決定是否清一份。
