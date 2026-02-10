ARG BUILD_FROM
FROM ${BUILD_FROM}

# Install runtime dependencies
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    bc \
    rclone \
    gzip \
    coreutils \
    util-linux \
    procps \
    nginx \
    python3 \
    py3-pip \
    py3-flask \
    && rm -rf /var/cache/apk/*

# Copy application files
COPY rootfs /

# Make scripts executable
RUN chmod +x /usr/local/bin/*.sh

# Ingress web UI port
EXPOSE 8099

# Entry point
CMD ["/usr/local/bin/run.sh"]
