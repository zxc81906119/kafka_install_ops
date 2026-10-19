# Simulated C3 host (c3-01): the node image + one PoC-only network rule.
# C3 is reached DIRECTLY by operators (bastion / VDI) - in the lab: Windows -> https://localhost:9021, published on the
# "opsnet" network. Docker gives a container on a non-internal network a default route, and Docker Desktop NATs it
# to the Internet; this unit removes that default route at every boot, so c3-01 keeps only its two directly
# connected subnets (cluster + operators) and stays offline like every other host. Replies to operators still work:
# they go back on the operators' subnet itself.
FROM cp-node:poc

COPY lab-no-default-route.service /etc/systemd/system/lab-no-default-route.service
RUN systemctl enable lab-no-default-route.service
