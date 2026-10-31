# 2026-10-31 手冊逐章實跑（使用者每章看完才往下）

- 用 `run-full.sh customer <章> <章>` 一章一章跑，每章列出指令、作用、結果給使用者看。第 0–13 章全部通過（rc=0、沒有可疑輸出）。
- 跑完要一起修的手冊小地方：
  - 4.5 out 寫 `host=kb01.poc.lab`，實跑是 `host=172.35.0.31`（sshd 沒反查）：out 不寫死主機名。
  - 10.4 格式化 controller 時 8.2.4 的 kafka-storage 印 `WARN 'share' in group.coordinator.rebalance.protocols is deprecated`（不是我們的設定）：out 補說明。
  - 13 章第 5 塊「帶 kafka_broker_id 的節點數」：檢查只要 >0 就停，印出當下回報到的數（這次 5，之後是 7 = 3 controller＋4 broker）；改成等到 7／7。
- 使用者決定：JMX exporter 7071 只用 HTTPS、拿掉 basic auth（redesign 2026-10-31）。第 17 章前先在 lab 手動試，再改手冊。
