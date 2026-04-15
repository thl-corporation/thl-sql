FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive \
    PUBLIC_HOST=localhost \
    PUBLIC_PORT=80 \
    PUBLIC_SCHEME=http \
    THL_NO_SYSTEMD=1

WORKDIR /opt/thl-sql

COPY . /opt/thl-sql

RUN chmod +x /opt/thl-sql/install.sh

CMD ["bash", "-lc", "tail -f /dev/null"]
