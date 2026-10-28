# untitled7 — Confluent Platform 離線安裝與遷移 PoC（銀行，8.2 → 8.3）

> **語言規則（最優先，每一則都適用）**：所有給使用者看的文字一律用**繁體中文**，英文只用在技術名詞與指令
> （dnf、RPM、versionlock、MDS、CyberArk、`kafka-features` …）。包括：做事過程中的進度說明、背景工作回報、
> 表格、最後的總結、問題選項。不要因為工具輸出或上一則是英文就跟著改用英文。使用者不需要再提醒。

PoC for installing Confluent Platform fully offline at a bank, as a **baseline + migration** path (decided 2026-10-27):
baseline CP 8.2.4 + Control Center 2.5.1 + JDK 21 + OS 9.6 (chapters 2–19), then migrate to CP 8.3.2 + C3 2.6.1 + JDK 25 + OS 9.8
(chapter 29 packages/JDK/finalize, chapter 30 OS minor update, chapter 31 C3 version swap). JDK 25 is not supported by 8.2.x, hence the baseline JDK 21;
C3 2.5.x supports CP up to 8.2.x and 2.6.x up to 8.3.x, so C3 is upgraded first. Versions live in `install/conf/site.env` (`CP_VERSION` … baseline, `*_TARGET_*` target).
Simulated hosts run in Docker Desktop on Windows 11 (project `lab`, built from `~/kafka-lab`); driven from Git Bash.
Details of the architecture and every component: @README.md

## Working with the user
- Reply in **繁體中文**; technical terms stay in English (dnf, RPM, versionlock, MDS, CyberArk …).
- Ask decisions as **single/multi-select choices** (AskUserQuestion), not prose.
- The manual (`docs/journey-src/journey.md`) is **hand commands first**; `install/steps/NN-*.sh` automate the same
  path. New procedures are validated by running the raw commands on the lab, never only through the scripts.
- Every chapter follows three steps: **hand-run on the lab → write the manual (concept diagram before the text) → wrap as a script**. If chapter order is
  wrong or chapters can merge, restructure first and test after; wrong content is simply fixed (user, 2026-10-28).
- The user drives the design discussion (`redesign/README.md`); record only confirmed decisions and open questions.
- Never print a password, key or token in chat. Secrets live in 0600 files (`~/secrets/*.pass`, `~/pki/store.pass`,
  `~/kafka-lab/secrets.env`) and are read into variables at run time.

## Session start and hand-off (skill `handoff`)
- First: `git branch --show-current` + `git worktree list`, then read `.claude/state/status-<branch>.md` and the
  newest entries in `.claude/state/log/`. Summarise where things stand before doing anything.
- Update the status file at every milestone (step verified, decision made, document produced, lab state changed);
  add a dated log file for each topic. Auto-memory holds only user preferences, never project state.
- One session = one git worktree = one branch. The Docker lab is shared: note "lab 使用中" in the status file.

## Repository map
- `docs/journey-src/` — `journey.md` (the hands-on guide, chapters 1–31 plus appendix A = build the lab, appendix B = monitoring coverage and lab tear-down; single `customer` mode)
  + `diagrams.js` → `docs/Confluent-安裝旅程-手把手.docx`; `tools/run-full.sh customer [from] [to]` (chapter ids 1–31/A/B, both inclusive; run order A, 1…31, B; default A→B) runs the guide's
  blocks on the lab (`run-chapter.js` extracts them, `scan-log.sh` flags rc=0 output that is really a failure).
- `docs/questions-src/questions.md` → `docs/Confluent-請銀行確認的事項.docx` (`node build.js`).
- `docs/deck-src/install.js` + `install-steps.js` → `docs/Confluent-RPM安裝流程.pptx` (14-page deck for bank managers).
- `install/` — installer that follows the guide one script per chapter (`install.sh`, `steps/02–30` named by chapter; chapters 7 and 25 are `07-1/2/3-*.sh` and `25-1/2-*.sh`, `conf/site.env`);
  `install/lab/` = lab-only (`bank-sim.sh` plays the bank, `run-customer.sh` = the whole path from zero: baseline → acceptance → migration → OS 9.8 → C3; no separate upgrade drill).
- `opmenu/` — OP menu source (the **only** copy; never edit a sibling project such as `untitled6`).
- `redesign/README.md` — design decisions, lessons, open questions.
- Generated documents: edit the sources, then rebuild (skill `build-docs`).
- Not in git: `*.p12|*.pem|*.key|*.crt`, `secrets.env`, licences, packages (the lab's landing zone is `~/kafka-lab/landing`: `rpm/` = baseline set, `rpm-target/` = migration target set, `bank/` = both JDK tars; the bank's OS repo content is `~/kafka-lab/bank-os/{9.6,9.8-updates,9.8}`, outside the landing zone).

## Branches
- `redesign` — current work. The old cpctl PoC (`installer/`, `docker/` cp-poc/cp-man labs, `windows/` tools, old
  manual, PoC deck, host checklist, bastion jump01 design) was removed on 2026-10-25; it survives only on `main`.
  Don't consult `main` for current design.
- Commit only when asked; never push unless asked; never commit secrets, licence or packages.

## Lab facts
- One lab: project `lab` (14 containers + `dl01`, subnets 172.35/172.36), built from `~/kafka-lab` per journey chapter 0. Host image `lab-node:96` (Rocky 9.6 from the vault; the old 9.8 image is `lab-node:1`, never reuse it), web image `lab-web:96`.
  Docker Desktop VM has ~10.7 GB, so never run anything else alongside it.
- Enter hosts: `docker exec -it -w /root lab-ops02-1 bash` (ops02 as **root** = what PSMP gives a person; no PVWA/PSMP in the lab),
  `docker exec -it lab-<host>-1 bash` (root, "bank" actions). Prefix docker commands with `MSYS_NO_PATHCONV=1`
  and pass Windows paths through `cygpath -m` (Node is a Windows program: convert paths before handing them over).
- ops02 → all hosts: user `cpuser` (UID/GID 1500, locked password), one key `/secure/ssh/cpuser_ed25519` (root 0400) on the
  separate file system simulated by docker volume `ops-secure` (no LUKS); `~/.ssh/config` makes plain `ssh kb01.poc.lab` use it.
  It survives restarts (volume), nothing to re-paste. Platform secrets live only on ops02 (`~/secrets`, `~/pki`, root 0600); there is no vault simulation.
- Bind mounts of Windows folders (9p) are slow for multi-GB reads: download inside the container, then copy out.
- After a Docker Desktop restart check `docker ps --format '{{.Names}}' | cut -d- -f1 | sort | uniq -c`.
- If every container's `timeout 5 ip addr` hangs, the VM's netlink is wedged: restart Docker Desktop, don't debug configs.
- In the lab Claude plays the bank (`install/lab/bank-sim.sh`, or the guide's 銀行 blocks): AD (samba-tool on ad01),
  CA (`~/kafka-lab/ca`), OS repo and NTP on repo01, nginx on lb01, the OS team (cpuser account, sshd drop-in, public key line with `from=`, install-period sudo on every host incl. ops02; `bank-sim.sh prepare`),
  monitoring (Prometheus, Alertmanager, Grafana, webhook receiver) as four
  `lab-mon-*` containers (`bank-sim.sh monitoring`; remove them with `monitoring-stop` before any `down -v`).

## Design decisions in force (details: redesign/README.md)
- RPM install only; Confluent packages are the only files we bring in; OS packages come from the bank's repo
  (Satellite / Nexus / plain httpd — all look the same to dnf).
- JDKs (21 for the baseline, 25 for the migration) are delivered by the bank as tars; we install to `/opt/java/<dir>` + `/opt/java/current`, register
  `java`/`keytool` with `alternatives`, set `JAVA_HOME` in `/etc/profile.d/java.sh` and in each systemd drop-in.
- Only Confluent packages and the JDK are version-locked; C3's `cyrus-sasl`/`openssl-devel` follow OS patching.
- `super.users` is only `kafka-internal` (service-to-service). `svc-ops` (ops host, certificate) and `kafka-admin` (emergency SCRAM) are `SystemAdmin` via
  RBAC; chapter 11 bootstraps the first binding with the `kafka-internal` certificate. Authorization is decided by each broker from `_confluent-metadata-auth`, so
  MDS/AD outages do not affect it (drill 11.2 stops ad01).
- Apps connect directly with SCRAM; apps via REST Proxy must use client certificates (REST has no password path).
- Humans use AD accounts; RBAC binds AD groups, never individuals. Platform services use certificates, not AD.
- CyberArk is decoupled from the platform (decided 2026-10-28): the only link is that a person logs in to the PVWA web page (AD + MFA) and PSMP
  logs them in to ops02 as root. Platform secrets (passphrase, master key, SCRAM, svc-mds-bind, breakglass PEM, license) live only on ops02 in root-only
  0600 files; nothing is vaulted; no CPM rotation — root is the bank's, `svc-mds-bind` is rotated by hand and the bank must tell us (update cipher text, rolling restart).
- One SSH key pair (ed25519), private key only on ops02 in a separate encrypted file system `/secure/ssh` (root 0400), not in CyberArk, not backed up;
  ops02 rebuilt = new pair + OS team redeploys the public key. Public key in each host's `cpuser` authorized_keys with only `from="<ops02 IP>,127.0.0.1,::1"`.
  Rotation is manual (new+old coexist, guide 20.5). `cpuser` sudo: full `NOPASSWD` during install/upgrade, afterwards only `/etc/sudoers.d/cpuser-ops`
  listing every unit and exact command form (sudoers matches the whole argument list; no `confluent-*` wildcard).
- ops02 is both the install host and the operators' login point (OP menu runs there as root); no separate bastion. Because operators are root, the menu's
  host-level permission check is a process control, not a hard barrier; traceability = CyberArk login records + PSMP recording.
- Monitoring (chapter 17): JMX exporter on controllers, brokers, REST Proxy, C3; Prometheus, Alertmanager and Grafana are the bank's, we deliver
  config + Confluent's official jmx-monitoring-stacks files (pinned commit, brought in through chapters 2-3). C3's embedded Prometheus/Alertmanager stay
  untouched and are not used for alerting (no C3 alert triggers/actions).
- MDS token key pair is fixed (rotate only on compromise); cpuser sudo is `NOPASSWD` during install.

## Gotchas learned the hard way
- A Rocky 9.6 image's default repo files point at the **latest 9.x** (mirrorlist with `$releasever` = 9): `dnf install` there installs 9.8 packages. Freeze to the vault (`dl.rockylinux.org/vault/rocky/9.6`, repo ids `vault96-*`); 9.8 lives in `pub/rocky/9.8`, 9.6 is not in `pub`.
- Lab hosts are containers on the WSL2 kernel: `systemctl reboot` fails ("Could not activate remote peer"); `systemd-detect-virt -c` answers `wsl`/`docker`. Chapter 30 / `30-os-patch.sh` / `rest-restart.sh -r` restart the platform services instead. A kernel update cannot be tested in the lab.
- `dnf update` from a `file://` repo that is also the `--downloaddir` can delete the RPMs it just used: copy the downloaded set before indexing/using it.
- Before `systemctl start` of an RPM service, confirm the drop-in is in effect:
  `systemctl show <unit> -p ExecStart` must point to **our** properties file, else the RPM default config starts
  (REST Proxy came up as plain HTTP that way).
- `systemctl enable --now` does not restart a running service; after config changes use `restart`.
- `/etc/confluent/ssl`, `/var/lib/kafka` are 0750: verification commands need `sudo ls`/`sudo stat`.
- C3 must own `/etc/confluent-control-center/*-generated.yml` (`cp-control-center:confluent`).
- `dnf` metadata is cached 48 h: use `--refresh` right after publishing to the repo.
- Confluent CLI v4 `confluent secret … --passphrase` takes the **value** (`"$(cat file)"`); `@file` and `-` are used
  literally as the passphrase (everything "works", but the real passphrase is never used and the next rotate after a
  rename fails). `kafka-configs` echoes the whole config, passwords included, on error: send its output to /dev/null.
- `kafka-configs --add-config-file` rejects SCRAM credentials (reads `SCRAM_SHA_512`); use `--add-config`.
- Windows Git Bash has no real `python3` (it is the Microsoft Store stub: silent, exit 0): run Python inside a container or on ops02.
- Never edit a bash script that is running (`install/lab/run-customer.sh`, `tools/run-full.sh` runners): bash reads the file as it goes, so later
  stages execute the edited text against the old copy already pushed to ops02 (2026-10-28: a run died at stage 17 looking for the renamed `29-upgrade.sh`).
- Check run logs line by line, not only `scan-log.sh`: an empty value after "：" means the check's precondition was missing.
- Building a package set with `dnf download --resolve`: use a clean container and download **before** installing
  tools, or the tools' dependencies are missed (`createrepo_c-libs`).
