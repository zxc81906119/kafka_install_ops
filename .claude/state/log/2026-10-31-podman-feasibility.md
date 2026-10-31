# 2026-10-31 Podman（CLI＋machine on WSL2）可行性測試

- 安裝：Podman v6.1.4 `podman-installer-windows-amd64.msi`（27.2 MB，GitHub releases；sha256 與 shasums、API digest 一致；Authenticode Valid，Red Hat, LLC）。安裝過程把 WSL 重設，Docker Desktop 跟著被關掉（lab 容器沒有正常停止；重開 Docker 後 14 台自己回來、服務與 MDS 正常）。
- 使用者要求刪掉舊的 `podman-machine-default`（9/16 建）：已 `podman machine rm`。新建 `labtest`（`--rootful --cpus 4`；WSL 上 --memory 無效，記憶體由 WSL 統一管）：Fedora 44、kernel 6.18 WSL2、cgroup v2、netavark、約 11 GB。測完停止、保留。
- 結果（縮小版 compose：ops02＋kb01，x-node 設定照抄 lab 的 compose.yml）：
  - build `lab-node:96`：47 秒，Rocky 9.6（名稱是 localhost/lab-node:96，compose 的 image: lab-node:96 找得到）。
  - docker-compose v5.5.1 接 Podman（DOCKER_HOST=npipe:////./pipe/docker_engine）：容器名 `lab-ops02-1`、`lab-kb01-1`，volume `lab_ops-secure`——和 Docker 相同；`podman compose` 也會呼叫同一支 docker-compose。
  - privileged＋cgroup: host＋掛 /sys/fs/cgroup：systemd running（PID1 systemd）、sshd active、無失敗單元；固定 IP（兩個網段）、extra_hosts、TZ、ulimit nofile 都生效；labnet internal 連不到外網。
  - firewalld 能裝能起、firewall-cmd 可開埠；sysctl 可改，**net.core.rmem_max 也改得動**（Docker 下改不動，第 7 章 broker errors=2）。
  - docker cp 進出、exec -i 從 stdin 餵腳本、podman exec／cp（Git Bash）都正常；PowerShell 管線會加 BOM、傳參數方式不同，不要從 PowerShell 測。
  - 掛載 Windows 目錄可讀，200 MB 約 9.7 秒（9p 慢，和 Docker 一樣：大檔先在容器內下載再複製）。
  - 冷開機：machine stop/start 後容器**不會**自己回來，要在 machine 裡 `systemctl enable podman-restart.service`；啟用後兩台自動回來、systemd running。Windows 開機後 machine 本身不會自動啟動（要另外排工作排程器）。
  - `hostname -f` 只回短名：Docker 也一樣，不是差異。
  - Podman machine 起來時佔用 `\.\pipe\docker_engine`；Docker CLI 走自己的 desktop-linux context，兩者不能同時跑重負載（記憶體）。
- 結論：可行。真實度沒有提升（一樣共用 WSL2 kernel，不能真重開機、測 kernel 更新、LUKS），唯一實際改善是 net.core.* sysctl 改得動。要換的話：第 0 章（安裝 Podman、建 rootful machine、啟用 podman-restart、Windows 開機啟動 machine、DOCKER_HOST 或 alias）、bank-sim／run-full 的 docker 指令可沿用（compose 名稱相同）；要整輪從零實跑驗證。
- 決定換 Podman 後（redesign 2026-10-31）：docker-compose v5.5.1 從 Docker Desktop 複製到 `%LOCALAPPDATA%\Programs\docker-compose\`，`%APPDATA%\containers\containers.conf` 設 `[engine] compose_providers`（TOML 字串用正斜線；反斜線會被當成 \U 跳脫而讀不進去）。
- 第 2 步（手動在 Podman 上建 lab）：關掉 Docker Desktop（WSL 11 GB 共用），啟動 labtest；用 run-chapter.js 抽第 0 章，docker → podman 後照跑。只有 0.4 的映像計數失敗（`podman images` 名稱是 `localhost/lab-node:96`，`grep -cE '^lab-…'` 數成 0）→ 改 `(^|/)lab-` 後全部通過：4 個映像、CA、14 台、dl01 internet 200；11 台 systemd running，ad01 Samba、lb01 nginx、sshd 正常。
- 實跑工具要改：run-full.sh 3 行（拆 lab）、run-chapter.js 2 處（`docker exec -i … bash -c 'cat > /tmp/runner.sh'` 把指令塊送進主機）。
