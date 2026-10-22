# 2026-10-20 — 手動安裝實跑（cp-man）

- 使用者全程手動下指令，Claude 扮演銀行；1–19 項完成並驗證（詳細進度與踩坑：`redesign/README.md`「手動實測進度」）。
- 決定：RPM only；JDK 由銀行給 tar、我方裝；改用 alternatives；只鎖 Confluent 與 JDK；OP 選單不納入這次流程。
- 事故：Docker Desktop VM netlink 卡死 → Java 名稱解析卡 → broker TOKEN listener 堆 CLOSE-WAIT；重啟 Docker 解決。
  判斷法：任一容器 `timeout 5 ip addr` 卡住。
- 教訓：啟動 RPM 服務前看 ExecStart；`enable --now` 不重啟；`sudo ls` 看 0750 目錄；C3 generated yml 擁有者；
  `--refresh`；下載機先下載再裝工具。
