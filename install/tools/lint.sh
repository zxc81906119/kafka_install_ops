#!/usr/bin/env bash
# install/ 的靜態檢查：改完腳本、上 lab 之前先跑。
#   bash install/tools/lint.sh            在有 shellcheck 的機器跑（RHEL：EPEL 的 ShellCheck）
#   在 Windows Git Bash 沒有 shellcheck 時，自動改用 docker image cp-ops:poc（裡面有 ShellCheck）跑同一支
#
# 檢查三件事：
#   1. 每支 .sh 本身（shellcheck，warning 以上）
#   2. 送到遠端執行的 heredoc：ssh_script … <<'EOF' 與 NAME=$(cat <<'EOF' 的內容。
#      平常 shellcheck 把 heredoc 當純文字不看；這裡把它們抽出來、行號不變，另外檢查一次
#   3. 專案規則：開了 pipefail 的地方不准寫「指令 | grep -q」
#      （grep 找到就先結束，前面的指令被 SIGPIPE 打斷，整條管線變成失敗，判斷隨機出錯）
#      改寫成 grep -q 樣式 <<<"$(指令)"。送到別的 shell 的字串不受此限（那裡沒有 pipefail）
# 結束碼：0 乾淨；1 有問題（逐條列出 檔案:行:欄）
set -uo pipefail
INSTALL_ROOT=$(cd "$(dirname "$0")/.." && pwd)
LINT_IMAGE=${LINT_IMAGE:-cp-ops:poc}

# 沒有 shellcheck：用 docker 跑自己（install/ 唯讀掛進去、不連網）
if ! command -v shellcheck >/dev/null; then
  command -v docker >/dev/null || { echo "找不到 shellcheck，也沒有 docker"; exit 1; }
  windows_root=$INSTALL_ROOT
  command -v cygpath >/dev/null && windows_root=$(cygpath -m "$INSTALL_ROOT")
  MSYS_NO_PATHCONV=1 exec docker run --rm --network none -v "$windows_root:/install:ro" "$LINT_IMAGE" bash /install/tools/lint.sh
fi

cd "$INSTALL_ROOT" || exit 1
mapfile -t SHELL_FILES < <(find . -name '*.sh' | sort)
# 排除的規則與原因：
#   SC1090 SC1091  source 的路徑是算出來的（site.env、lib/*.sh），shellcheck 跟不過去
#   SC2034         有些變數是給 envsubst 的模板用的，腳本裡看起來「沒用到」
SHELLCHECK_EXCLUDES=SC1090,SC1091,SC2034
problem_count=0

echo "== 1. shellcheck：${#SHELL_FILES[@]} 支"
if ! shellcheck -x -S warning -e "$SHELLCHECK_EXCLUDES" -s bash -f gcc "${SHELL_FILES[@]}"; then problem_count=$((problem_count + 1)); fi

echo "== 2. 送到遠端的 heredoc"
# 抽出來的檔放暫存目錄：檔名是原檔路徑把 / 換成 __；heredoc 以外的行留空，行號和原檔一樣
FRAGMENT_DIR=$(mktemp -d)
trap 'rm -rf "$FRAGMENT_DIR"' EXIT
for source_file in "${SHELL_FILES[@]}"; do
  fragment_file=$FRAGMENT_DIR/$(sed 's|^\./||; s|/|__|g' <<<"$source_file")
  awk '
    NR == 1 { print "# shellcheck shell=bash"; next }
    inside && $0 == "EOF" { inside = 0; print ""; next }
    inside { print; next }
    /<<'\''EOF'\''/ && (/ssh_script/ || /=\$\(cat <<'\''EOF'\''/) && !/cat >/ { inside = 1; found = 1 }
    { print "" }
    END { exit found ? 0 : 1 }
  ' "$source_file" > "$fragment_file" || rm -f "$fragment_file"
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
# 只看指令本身的行：去掉註解行，去掉送到別的 shell 的字串（bash -c "…"、as_root_on、ssh_run、run_as_conjur_admin：那裡沒有 pipefail）
pipe_grep_lines=$(grep -n -E '\|[[:space:]]*grep -[a-zA-Z]*q' "${SHELL_FILES[@]}" | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v -E 'bash -c "|as_root_on|ssh_run|run_as_conjur_admin')
if [ -n "$pipe_grep_lines" ]; then
  echo "$pipe_grep_lines"
  echo "   ↑ 改寫成 grep -q 樣式 <<<\"\$(指令)\""
  problem_count=$((problem_count + 1))
fi

if [ "$problem_count" = 0 ]; then echo "全部乾淨"; exit 0; fi
echo "有 $problem_count 類問題（見上）"; exit 1
