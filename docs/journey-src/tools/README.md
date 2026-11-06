# tools/run-chapter.js — 把 journey.md 的一章變成可執行的腳本（實跑驗證用）

```bash
node tools/run-chapter.js journey.md 15 16 /tmp/ch15.sh   # 第 15 章（到第 16 章之前）
bash /tmp/ch15.sh > /tmp/ch15.log 2>&1
```

- 每個 ```bash 區塊依最近的 `@role 誰 | 主機 | 身分` 決定在哪跑：`Windows 終端` → 本機 Git Bash；`dl01` → `podman exec dl01`；其他主機 → `podman exec lab-<主機>-1`，操作機（ops02）一律以 root 進（`-w /root`；ssh 到各主機靠 root 的 `~/.ssh/config` 指到 `/secure/ssh/cpuser_ed25519`，不需要傳 ssh-agent）。
- 同一主機連續的區塊共用一個 shell（像讀者留在那台沒登出），腳本經 `/tmp/runner.sh` 餵進去、stdin 接 /dev/null（ssh 才不會吃掉後面的指令）。
- 含 `-it` 的區塊、`@role … | — | —` 的區塊會略過；任一區塊 rc≠0 就停。
- 用途：改了章節後重跑，把實際輸出對回 ```out 區塊。

## lint-commands.js：指令寫法檢查

```bash
node tools/lint-commands.js                  # 手冊、install、opmenu 全部
node tools/lint-commands.js --summary        # 只看各規則的筆數
node tools/lint-commands.js journey.md 21    # 只看手冊第 21 章
```

規則在 `COMMAND-STYLE.md`（2026-11-05 使用者定案）：一行一個指令、完整的 `if`、不用 `&&`／`||` 串接、一行不超過 120 字、管線最多 3 段、不巢狀 `$( )`、不用 jq；手冊人照打的指令不定義函式，一塊最多 60 行。例外要在那一行或上一行寫 `# lint-ok: 原因`。手冊寫到磁碟的腳本（`cat > x.sh <<'EOF'`）也照 shell 規則檢查，只是可以有函式。

## run-full.sh：整條主線

```bash
bash tools/run-full.sh customer          # 第 0 章到最後 = 基底（8.2.4／C3 2.5.1／JDK 21／OS 9.6）→ 第 21 章遷移 → 第 26 章 OS 9.8 → 第 27 章；先拆掉 lab，只留 ~/kafka-lab/landing 和 bank-os
bash tools/run-full.sh customer 21 22    # 只跑第 21 章（接著現有狀態）
```

跑之前它會先整理落地區版面（`bank-sim.sh landing-layout`：`rpm/` = 基底、`rpm-target/` = 目標；舊的 `landing-extra/` 併進來）。第 21、26 章的「每段後驗收」在文件裡只是一句「照第 19 章」，run-full 不會自己插入；要每段驗收就用 `install/lab/run-customer.sh`。
