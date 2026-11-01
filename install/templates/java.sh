# JDK for Confluent Platform (/opt/java/current; 21 at install, 25 after the chapter 29 migration). Services set JAVA_HOME in their systemd drop-in.
if [ -z "$JAVA_HOME" ]; then
  export JAVA_HOME=/opt/java/current
fi
