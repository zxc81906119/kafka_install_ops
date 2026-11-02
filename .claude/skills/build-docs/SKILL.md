---
name: build-docs
description: Rebuild one of the generated documents in docs/ (RPM deck, journey docx, bank questions docx) after editing its source. Use whenever a .pptx/.docx/.xlsx under docs/ must change.
---

# Rebuild generated documents

Never edit the `.pptx` / `.docx` directly — change the source and rebuild. All generators are Node;
dependencies are already installed (`npm ci` only on a fresh clone).

| Document | Source | Command (from repo root) |
|---|---|---|
| `docs/Confluent-RPM安裝流程.pptx` | `docs/deck-src/install.js`, `install-steps.js` | `cd docs/deck-src && node install.js "../Confluent-RPM安裝流程.pptx"` |
| `docs/Confluent-手冊導覽.pptx` | `docs/deck-src/guide-slides.js`, `journey-src/diagrams.js` | see `docs/deck-src/README.md` (`guide.js`, then `guide-build.ps1` in PowerPoint with the company template) |
| `docs/Confluent-安裝旅程-手把手.docx` | `docs/journey-src/journey.md`, `diagrams.js` | `cd docs/journey-src && node build.js` |
| `docs/Confluent-請銀行確認的事項.docx` | `docs/questions-src/questions.md` | `cd docs/questions-src && node build.js` |

## Rules
- `install.js` **requires the output path argument**; without it the deck lands in `docs/deck-src/install.pptx`
  and the real file is untouched (this happened once — the user saw no change).
- `EBUSY` on write means PowerPoint/Word has the file open: ask the user to close it, then rebuild. Do not
  write to a `-new` copy unless the user asks.
- Deck wording rules for the RPM deck: "元件" not "角色"; the host is "操作機"; no script names; apps use SCRAM
  directly, certificates only via REST; package repo = "內部套件庫（Satellite/Artifactory/Nexus，無則 web server）".
- Markdown subset accepted by the questions/journey builders: `#`–`###`, paragraphs, `- ` bullets, `1. ` numbers,
  fenced code (journey: ```bash = command block, ```out = expected output), `|` tables, `> ` callouts
  (`>!` or "注意/陷阱" = warning), `[[toc]]`, `[[pagebreak]]`. Journey only: `@role 誰 | 主機 | 身分` badge lines, `@only` mode scopes (only the `customer` mode remains since 2026-10-27; every @only section needs its own @role),
  and `![diagram-id]` images from `diagrams.js`.
- Diagrams: render to PNG for a visual check before shipping:
  `node -e 'const D=require("./diagrams");const {Resvg}=require("@resvg/resvg-js");...'` then Read the PNGs.
- No PDF/image rendering of docx/pptx is available on this machine; tell the user you could not preview layout.
- Edit text with the Edit tool or a small Node script with exact-string replacements; `sed` with CJK and
  backslashes has bitten us repeatedly.
