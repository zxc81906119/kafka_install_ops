# tools/run-chapter.js — 把 journey.md 的一章變成可執行的腳本（實跑驗證用）

```bash
node tools/run-chapter.js journey.md 15 16 /tmp/ch15.sh   # 第 15 章（到第 16 章之前）
bash /tmp/ch15.sh > /tmp/ch15.log 2>&1
```

- 每個 ```bash 區塊依最近的 `@role 誰 | 主機 | 身分` 決定在哪跑：`Windows 終端` → 本機 Git Bash；`dl01` → `docker exec dl01`；其他主機 → `docker exec lab-<主機>-1`，身分 cpadmin 時加 `-u cpadmin -w /home/cpadmin`。
- 同一主機連續的區塊共用一個 shell（像讀者留在那台沒登出），腳本經 `/tmp/runner.sh` 餵進去、stdin 接 /dev/null（ssh 才不會吃掉後面的指令）。
- 含 `-it` 的區塊、`@role … | — | —` 的區塊會略過；任一區塊 rc≠0 就停。
- 用途：改了章節後重跑，把實際輸出對回 ```out 區塊。
