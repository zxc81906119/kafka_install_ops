---
name: manual-step
description: Guide the user through an installation or operations step with raw commands (no cpctl, no wrapper scripts): who runs it, where, the one-line command, the expected output, and the verification. Use when the user is walking through the manual install ("繼續", "下一步", "給我指令") or asks for a procedure to run by hand.
---

# Format of a hand-run step

The user types every command themselves (including bank-side ones in the lab). Give, per step:

1. **Role line** — 我方 (小安 / cpadmin) or 銀行 (which team), the host, the account.
2. **One sentence** on why; no essays.
3. **Command** in a `bash` block — a single pasteable line per step (loops over hosts are fine; heredocs are
   pasted whole). Variables with secrets are read from 0600 files: `$(cat ~/secrets/x.pass)`, `-passout file:`.
4. **Expected output** — the exact lines the user should see (or "N 行都是 …").
5. **Verification** that the step took effect, with `sudo` where the target is 0750.

Checklist before handing a service-start command:
- The systemd drop-in is in effect: `systemctl show <unit> -p ExecStart --value` shows our properties file.
- Use `systemctl restart` after config changes (`enable --now` does nothing for a running unit).
- Directories/files created with `install -d -o -g -m` / `install -m`, not `mkdir`+`chmod` pairs.
- Absolute paths (`~/pki/certs/...`), never paths relative to the current directory.
- `dnf` right after a repo publish: add `--refresh`.

Host inventory (cp-man / journey): controllers kc01-03 (node.id 1-3), brokers kb01-04 (101-104, racks a/a/b/b),
rest01-02, c3-01, ops02; ports 9092 internal, 9093 controller, 9094 token, 9095 client, 9096 ldap, 8090 MDS,
8082 REST, 9021 C3, 9090 Prometheus, 7071 JMX exporter.

Reference material for exact commands and outputs: `docs/journey-src/journey.md` (the validated run of
2026-10-20) and `docs/manual-src/guide.md`. When a step fails, diagnose on the lab yourself (logs, `ss`, thread
dumps) and give the user the fix as the next step — do not ask them to debug.

After a step is confirmed, append anything new (a pitfall, a corrected command) to `redesign/README.md`.
