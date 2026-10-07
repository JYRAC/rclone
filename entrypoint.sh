#!/bin/sh
set -e
exec rclone serve s3 gdrive: \
  --addr ":10000" \
  --poll-interval 0 \
  --auth-key "${RCLONE_S3_ACCESS_KEY},${RCLONE_S3_SECRET_KEY}"
