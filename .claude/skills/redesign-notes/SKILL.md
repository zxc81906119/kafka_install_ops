---
name: redesign-notes
description: Record design discussion outcomes in redesign/README.md (decisions, open questions, lessons, customer questions). Use when the user states a decision ("定案", "改成…", "不用…"), when a lab run reveals a pitfall, or when preparing questions for the customer or a vendor.
---

# Keeping redesign/README.md

The user leads the discussion ("我來說明為主"). Claude listens, restates, asks only for what is unclear, and
writes down **only what was confirmed**. Never put unapproved proposals in the file.

Structure already in the file:
- Flow table (22 items) with a status column — update the status when an item is decided or excluded.
- One section per discussed item: `### 已確認` table, `### 待確認` list, `### 影響` (what changes elsewhere).
- `## 11. …（CyberArk）` written in the user's plain, conversational tone — keep that tone for new sections.
- `## 手動實測進度` with the progress table and `### 踩到的坑` — append pitfalls there.

Conventions:
- Dates absolute (2026-10-21), not "今天".
- Decisions that reverse an earlier one: say so explicitly ("原先…的決定作廢").
- Questions for the customer / vendors go in a `請確認` or `問 … 原廠` block, phrased so they can be pasted into
  an email. Keep each list ≤ 4 questions.
- Do not duplicate what the code or README already records; link instead.
- The file is on branch `redesign`; do not commit unless asked.
