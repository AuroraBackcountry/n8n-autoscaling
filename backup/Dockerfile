# Single-stage Alpine build: pg_dump 17 matches the pgvector/pg17 server,
# and everything runs on musl. (Upstream's multi-stage build copied Alpine
# binaries into a Debian image, which fails at exec time — missing musl loader.)
FROM alpine:3.21

RUN apk add --no-cache \
    python3 \
    py3-pip \
    rclone \
    postgresql17-client \
    gnupg \
    tar \
    gzip

WORKDIR /app

# Install Python dependencies (pure-Python: dotenv, croniter, redis)
COPY backup/requirements.txt .
RUN pip install --no-cache-dir --break-system-packages -r requirements.txt

# Create backup working directory and empty default rclone config
RUN mkdir -p /backups /config/rclone && \
    touch /config/rclone/rclone.conf

# Copy application
COPY backup/backup.py .

CMD ["python3", "-u", "backup.py"]
