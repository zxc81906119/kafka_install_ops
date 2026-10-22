item 15 1 n n "查看 application 連線狀況" "在線的 consumer group 與成員數"
run() {
  be_kafka kafka-consumer-groups --list | grep -v '^_' | while read -r g; do
    [ -n "$g" ] || continue
    printf '%-30s %s\n' "$g" "$(be_kafka kafka-consumer-groups --describe --group "$g" --members 2>/dev/null | grep -c -E '^[^ ]+ +[^ ]+ +/')個成員"
  done
}
