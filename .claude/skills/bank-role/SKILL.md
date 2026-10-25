---
name: bank-role
description: Perform the bank-side preparations in the lab (AD objects, LDAPS cert, CA signing, OS package repo, NTP, load balancer, SSH key distribution, secret hand-over). Use when the user says "你扮演銀行", a step needs something the bank provides, or a CSR must be signed.
---

# Playing the bank in the lab

In production these are done by the bank's OS / AD / CA / network teams. In the lab Claude does them as root
inside the containers. Always say which bank role is acting and keep the production-equivalent in one line.

## Catalogue (containers `lab-<host>-1` in ~/kafka-lab; scripted: `install/lab/bank-sim.sh`)

| Need | Where | How |
|---|---|---|
| Host accounts + SSH public key | shared `authorized_keys.d` volume (write via ops02 as root) | `install -m 0644 /dev/stdin /etc/ssh/authorized_keys.d/cpadmin <<<"$pub"`; same file name `repodeploy` for repo01 |
| OS package repo (stands in for Satellite) | repo01 `/var/www/repo/os/` | clean `lab-node:1` container with `--disablerepo=* --enablerepo=baseos,appstream,extras`: **download first, then** `dnf install createrepo_c`, `createrepo_c /out`; `docker cp` into repo01; `chown -R repodeploy` |
| Repo definition + bank root trust on every host | each node | `/etc/yum.repos.d/bank-os.repo` (baseurl `https://repo01.poc.lab/os/`, gpgkey Rocky key), root cert → `/etc/pki/ca-trust/source/anchors/`, `update-ca-trust`, `rpm --import` |
| JDK | `landing/bank/` | tar + `.sha256`; the bank does **not** install it |
| AD | ad01 (`samba-tool`) | OUs `OU=Confluent` + `Users/Groups/Service`; groups `kafka-admins kafka-operators kafka-devs`; `svc-mds-bind` (read-only); users alice/bob/carol; passwords generated into `/root/secrets/*.pass`, handed to ops02 `~/secrets/` as 0600 files |
| LDAPS certificate | ad01 | CSR with SAN + `extendedKeyUsage=serverAuth` → sign → `/var/lib/samba/private/tls/{key,cert,ca}.pem`, `pkill -x samba` (entrypoint restarts it) |
| Certificate signing | Windows: `bash ~/kafka-lab/ca/sign.sh <csr> <out>` (G2 issuing CA: `ca/g2/sign.sh`) | policy: RSA ≥ 2048, CN present, not a CA, EKU **must** be in the CSR and ⊆ {serverAuth, clientAuth}; answer = leaf + issuing CA. Copy CSRs out of ops02 with `docker cp`, answers back into `~/pki/incoming/`, `chown cpadmin` |
| NTP | repo01 (`chronyd`, `local stratum 10`, `allow 172.35.0.0/24`) | nodes point `server repo01.poc.lab iburst` |
| Load balancer | lb01 `/etc/nginx/stream.d/cp.conf` | L4 passthrough 8082 → rest01/rest02 (`hash $remote_addr consistent`); 9021 → c3-01 only for the Windows port mapping; `nginx -t && nginx -s reload` |
| sudo for cpadmin | node image sudoers (full NOPASSWD in the lab) | after delivery only the narrow `cpadmin-ops` rule (guide 20.5) |
| PVWA (CyberArk PAM) | Windows `~/kafka-lab/pvwa/` (0600 files) | storing = copy the file in; retrieving = paste into ops02 (`docker exec -i … < pvwa/x`); keep the old value as `.prev` |

## Rules
- Paths for `docker cp`: container side `name:/path`, host side `"$(cygpath -m ...)"`; never a bare `/c/...` with
  `MSYS_NO_PATHCONV=1` (it becomes `C:\c\...`).
- Secrets are generated with `openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20`, stored in files, passed
  through `-e VAR=...` to `docker exec`; never echo them, never put them in chat.
- After any bank change, tell the user what the bank "delivered" (paths, names, fingerprints) so the user can
  continue with their own commands.
