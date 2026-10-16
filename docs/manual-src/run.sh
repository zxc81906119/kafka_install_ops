#!/usr/bin/env bash
# Transcript runner for the manual walkthrough: run < cmdfile   (LOG=<file>)
# Every command, its output and its exit code go to $LOG - the raw evidence behind the manual.
#   "#" lines      are logged as notes
#   one line       = one command
#   "{{" ... "}}"  = one multi-line command (heredocs etc., pasted as written in the manual)
LOG=${LOG:?set LOG}
exec_cmd() {
  printf '\n$ %s\n' "$1" | tee -a "$LOG"
  bash -c "$1" </dev/null 2>&1 | tee -a "$LOG"
  printf '[rc=%s]\n' "${PIPESTATUS[0]}" | tee -a "$LOG"
}
block="" inblock=0
while IFS= read -r line || [[ -n $line ]]; do
  if [[ $inblock == 1 ]]; then
    if [[ $line == "}}" ]]; then exec_cmd "$block"; inblock=0; block=""; else block+="$line"$'\n'; fi
    continue
  fi
  [[ -z $line ]] && continue
  if [[ $line == "{{" ]]; then inblock=1; continue; fi
  if [[ $line == \#* ]]; then printf '%s\n' "$line" | tee -a "$LOG"; continue; fi
  exec_cmd "$line"
done
