FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl iproute2 iptables netcat-openbsd python3 ufw util-linux && rm -rf /var/lib/apt/lists/*
COPY configure-work-ufw-policy.sh /usr/local/sbin/configure-work-ufw-policy
RUN chmod 0750 /usr/local/sbin/configure-work-ufw-policy && useradd --create-home --shell /bin/bash local-gpt-work
CMD ["sleep", "infinity"]
