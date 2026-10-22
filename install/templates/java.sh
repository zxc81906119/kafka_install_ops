# JDK 21 for Confluent Platform (/opt/java/current). Services set JAVA_HOME in their systemd drop-in.
[ -n "$JAVA_HOME" ] || export JAVA_HOME=/opt/java/current
