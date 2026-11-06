FROM debian:bookworm-slim
ARG TARGETARCH
ARG ENGRAM_VERSION=2.2.1
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl tar && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10003 --create-home engram && mkdir /data && chown engram:engram /data
RUN set -eu; case "$TARGETARCH" in amd64|arm64) ;; *) exit 1;; esac; \
    base="https://github.com/Gentleman-Programming/engram/releases/download/v${ENGRAM_VERSION}"; \
    archive="engram_${ENGRAM_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    curl -fsSL "$base/$archive" -o /tmp/engram.tar.gz; \
    curl -fsSL "$base/checksums.txt" -o /tmp/checksums.txt; \
    expected="$(awk -v file="$archive" '$2 == file {print $1}' /tmp/checksums.txt)"; \
    test -n "$expected"; echo "$expected  /tmp/engram.tar.gz" | sha256sum -c -; \
    tar xzf /tmp/engram.tar.gz -C /usr/local/bin engram; \
    rm /tmp/engram.tar.gz /tmp/checksums.txt
ENV ENGRAM_DATA_DIR=/data ENGRAM_PROJECT=makima-personal
USER 10003
CMD ["engram", "serve"]
