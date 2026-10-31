# tools/run-chapter.js — 把 journey.md 的一章變成可執行的腳本（實跑驗證用）

```bash
node tools/run-chapter.js journey.md 15 16 /tmp/ch15.sh   # 第 15 章（到第 16 章之前）
bash /tmp/ch15.sh > /tmp/ch15.log 2>&1
```

- 每個 ```bash 區塊依最近的 `@role 誰 | 主機 | 身分` 決定在哪跑：`Windows 終端` → 本機 Git Bash；`dl01` → `podman exec dl01`；其他主機 → `podman exec lab-<主機>-1`，操作機（ops02）一律以 root 進（`-w /root`；ssh 到各主機靠 root 的 `~/.ssh/config` 指到 `/secure/ssh/cpuser_ed25519`，不需要傳 ssh-agent）。
- 同一主機連續的區塊共用一個 shell（像讀者留在那台沒登出），腳本經 `/tmp/runner.sh` 餵進去、stdin 接 /dev/null（ssh 才不會吃掉後面的指令）。
- 含 `-it` 的區塊、`@role … | — | —` 的區塊會略過；任一區塊 rc≠0 就停。
- 用途：改了章節後重跑，把實際輸出對回 ```out 區塊。

## run-full.sh：整條主線

```bash
bash tools/run-full.sh customer          # 第 0 章到最後 = 基底（8.2.4／C3 2.5.1／JDK 21／OS 9.6）→ 第 21 章遷移 → 第 26 章 OS 9.8 → 第 27 章；先拆掉 lab，只留 ~/kafka-lab/landing 和 bank-os
bash tools/run-full.sh customer 21 22    # 只跑第 21 章（接著現有狀態）
```

跑之前它會先整理落地區版面（`bank-sim.sh landing-layout`：`rpm/` = 基底、`rpm-target/` = 目標；舊的 `landing-extra/` 併進來）。第 21、26 章的「每段後驗收」在文件裡只是一句「照第 19 章」，run-full 不會自己插入；要每段驗收就用 `install/lab/run-customer.sh`。
