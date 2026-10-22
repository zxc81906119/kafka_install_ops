---
name: build-docs
description: Rebuild one of the generated documents in docs/ (RPM deck, PoC deck, manual docx, host checklist xlsx, journey docx) after editing its source. Use whenever a .pptx/.docx/.xlsx under docs/ must change.
---

# Rebuild generated documents

Never edit the `.pptx` / `.docx` / `.xlsx` directly — change the source and rebuild. All generators are Node;
dependencies are already installed (`npm ci` only on a fresh clone).

| Document | Source | Command (from repo root) |
|---|---|---|
| `docs/Confluent-RPM安裝流程.pptx` | `docs/deck-src/install.js`, `install-steps.js` | `cd docs/deck-src && node install.js "../Confluent-RPM安裝流程.pptx"` |
| `docs/Confluent-離線安裝PoC-全流程.pptx` | `docs/deck-src/build.js`, `numbers.json` | `cd docs/deck-src && node build.js "../Confluent-離線安裝PoC-全流程.pptx"` |
| `docs/Confluent-手動安裝手冊.docx` | `docs/manual-src/guide.md` | `cd docs/manual-src && node build.js` |
| `docs/Confluent-主機準備清單.xlsx` | `docs/checklist-src/build.js` (+ `installer/conf/versions.env`) | `cd docs/checklist-src && node build.js` |
| `docs/Confluent-安裝旅程-手把手.docx` | `docs/journey-src/journey.md`, `diagrams.js` | `cd docs/journey-src && node build.js` |

## Rules
- `install.js` **requires the output path argument**; without it the deck lands in `docs/deck-src/install.pptx`
  and the real file is untouched (this happened once — the user saw no change).
- `EBUSY` on write means PowerPoint/Word has the file open: ask the user to close it, then rebuild. Do not
  write to a `-new` copy unless the user asks.
- Deck wording rules for the RPM deck: "元件" not "角色"; the host is "操作機"; no script names; apps use SCRAM
  directly, certificates only via REST; package repo = "內部套件庫（Satellite/Artifactory/Nexus，無則 web server）".
- Markdown subset accepted by the manual/journey builders: `#`–`###`, paragraphs, `- ` bullets, `1. ` numbers,
  fenced code (journey: ```bash = command block, ```out = expected output), `|` tables, `> ` callouts
  (`>!` or "注意/陷阱" = warning), `[[toc]]`, `[[pagebreak]]`. Journey only: `@role 誰 | 主機 | 身分` badge lines
  and `![diagram-id]` images from `diagrams.js`.
- Diagrams: render to PNG for a visual check before shipping:
  `node -e 'const D=require("./diagrams");const {Resvg}=require("@resvg/resvg-js");...'` then Read the PNGs.
- No PDF/image rendering of docx/pptx is available on this machine; tell the user you could not preview layout.
- Edit text with the Edit tool or a small Node script with exact-string replacements; `sed` with CJK and
  backslashes has bitten us repeatedly.
