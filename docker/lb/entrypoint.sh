#!/usr/bin/env bash
set -euo pipefail
/usr/sbin/sshd
exec nginx -g 'daemon off;'
