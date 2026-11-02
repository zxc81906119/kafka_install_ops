#!/usr/bin/env bash
# install/tools/lint.sh —— install/ 的靜態檢查：改完腳本、上 lab 之前先跑
# where: 有 shellcheck 的機器（RHEL：EPEL 的 ShellCheck），或 Windows Git Bash（沒有 shellcheck 時自動改用原廠 podman image koalaman/shellcheck，LINT_IMAGE 可換）
#
#   bash install/tools/lint.sh
#
# 檢查三件事：
#   1. 每支 .sh 本身（shellcheck，warning 以上）
#   2. 送到遠端執行的 heredoc：ssh_script … <<'EOF' 與 NAME=$(cat <<'EOF' 的內容。
#      平常 shellcheck 把 heredoc 當純文字不看；這裡把它們抽出來、行號不變，另外檢查一次
#   3. 專案規則：開了 pipefail 的地方不准寫「指令 | grep -q」
#      （grep 找到就先結束，前面的指令被 SIGPIPE 打斷，整條管線變成失敗，判斷隨機出錯）
#      改寫成 grep -q 樣式 <<<"$(指令)"。送到別的 shell 的字串不受此限（那裡沒有 pipefail）
# 結束碼：0 乾淨；1 有問題（逐條列出 檔案:行:欄）
# 能不能重跑：可以，只讀不改。
set -uo pipefail
INSTALL_ROOT=$(cd "$(dirname "$0")/.." && pwd)
LINT_IMAGE=${LINT_IMAGE:-koalaman/shellcheck:v0.10.0}

# 沒有 shellcheck：每次呼叫改在 podman 裡跑（目前目錄唯讀掛進去、不連網；檔名都用相對路徑）
if ! command -v shellcheck > /dev/null; then
  if ! command -v podman > /dev/null; then
    podman_dir=$(cygpath -u "$LOCALAPPDATA")/Programs/Podman
    export PATH="$podman_dir:$PATH"
  fi

  if ! command -v podman > /dev/null; then
    echo "找不到 shellcheck，也沒有 podman"
    exit 1
  fi

  shellcheck() {
    local here=$PWD

    if command -v cygpath > /dev/null; then
      here=$(cygpath -m "$PWD")
    fi

    MSYS_NO_PATHCONV=1 podman run --rm --network none -v "$here:/mnt:ro" -w /mnt "$LINT_IMAGE" "$@"
  }
fi

if ! cd "$INSTALL_ROOT"; then
  exit 1
fi

mapfile -t SHELL_FILES < <(find . -name '*.sh' | sort)

# 排除的規則與原因：
#   SC1090 SC1091  source 的路徑是算出來的（site.env、lib/*.sh），shellcheck 跟不過去
#   SC2034         有些變數是給 envsubst 的模板用的，腳本裡看起來「沒用到」
SHELLCHECK_EXCLUDES=SC1090,SC1091,SC2034
problem_count=0

# extract_remote_heredocs <來源檔>：只留送到遠端的 heredoc 內容，其他行留空，行號和原檔一樣；一個都沒有時結束碼 1
#   ssh_script kb04 <<'EOF'   → 空行
#   sudo systemctl restart x  → sudo systemctl restart x
#   EOF                       → 空行
extract_remote_heredocs() {
  awk '
    NR == 1 { print "# shellcheck shell=bash"; next }
    inside && $0 == "EOF" { inside = 0; print ""; next }
    inside { print; next }
    /<<'\''EOF'\''/ && (/ssh_script/ || /=\$\(cat <<'\''EOF'\''/) && !/cat >/ { inside = 1; found = 1 }
    { print "" }
    END { exit found ? 0 : 1 }
  ' "$1"
}

echo "== 1. shellcheck：${#SHELL_FILES[@]} 支"
if ! shellcheck -x -S warning -e "$SHELLCHECK_EXCLUDES" -s bash -f gcc "${SHELL_FILES[@]}"; then
  problem_count=$((problem_count + 1))
fi

echo "== 2. 送到遠端的 heredoc"
# 抽出來的檔放暫存目錄：檔名是原檔路徑把 / 換成 __
FRAGMENT_DIR=$(mktemp -d)
trap 'rm -rf "$FRAGMENT_DIR"' EXIT

for source_file in "${SHELL_FILES[@]}"; do
  fragment_file=$FRAGMENT_DIR/$(sed 's|^\./||; s|/|__|g' <<<"$source_file")

  if ! extract_remote_heredocs "$source_file" > "$fragment_file"; then
    rm -f "$fragment_file"
  fi
done

mapfile -t FRAGMENT_FILES < <(find "$FRAGMENT_DIR" -type f | sort)
echo "   ${#FRAGMENT_FILES[@]} 支有遠端 heredoc"

# 遠端片段另外排除：SC2154（變數由 ssh_script 的 變數=值 帶過去，片段裡看不到賦值）
if [ "${#FRAGMENT_FILES[@]}" -gt 0 ]; then
  fragment_report=$(cd "$FRAGMENT_DIR" && shellcheck -S warning -e "$SHELLCHECK_EXCLUDES,SC2154" -s bash -f gcc ./* 2>&1)

  if [ -n "$fragment_report" ]; then
    sed 's|^\./||; s|__|/|g; s|^|   遠端 |' <<<"$fragment_report"
    problem_count=$((problem_count + 1))
  fi
fi

echo "== 3. 開 pipefail 的地方不寫「管線接 grep -q」"
# 只看指令本身的行：去掉註解行，去掉送到別的 shell 的字串（bash -c "…"、as_root_on、ssh_run：那裡沒有 pipefail）
pipe_grep_lines=$(grep -n -E '\|[[:space:]]*grep -[a-zA-Z]*q' "${SHELL_FILES[@]}" | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v -E 'bash -c "|as_root_on|ssh_run')

if [ -n "$pipe_grep_lines" ]; then
  echo "$pipe_grep_lines"
  echo "   ↑ 改寫成 grep -q 樣式 <<<\"\$(指令)\""
  problem_count=$((problem_count + 1))
fi

if [ "$problem_count" = 0 ]; then
  echo "全部乾淨"
  exit 0
fi

echo "有 $problem_count 類問題（見上）"
exit 1
