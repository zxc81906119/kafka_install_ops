# JDK for Confluent Platform (/opt/java/current; 21 at install, 25 after the chapter 21 migration). Services set JAVA_HOME in their systemd drop-in.
[ -n "$JAVA_HOME" ] || export JAVA_HOME=/opt/java/current
