# vault ブロック（接続先、証明書）は、entrypoint.sh が、経路に合わせて作って、この前に付ける。

auto_auth {
  method {
    type = "token_file"
    config = {
      token_file_path = "/tmp/vault-token"
    }
  }
}

env_template "RCLONE_CONFIG_GDRIVE_CLIENT_ID" {
  contents = "{{ with secret \"kv/data/secrets/rclone/config\" }}{{ .Data.data.client_id }}{{ end }}"
}

env_template "RCLONE_CONFIG_GDRIVE_CLIENT_SECRET" {
  contents = "{{ with secret \"kv/data/secrets/rclone/config\" }}{{ .Data.data.client_secret }}{{ end }}"
}

env_template "RCLONE_CONFIG_GDRIVE_TOKEN" {
  contents = "{{ with secret \"kv/data/secrets/rclone/config\" }}{{ .Data.data.token }}{{ end }}"
}

env_template "RCLONE_S3_ACCESS_KEY" {
  contents = "{{ with secret \"kv/data/secrets/shared/rclone-gdrive\" }}{{ .Data.data.access_key }}{{ end }}"
}

env_template "RCLONE_S3_SECRET_KEY" {
  contents = "{{ with secret \"kv/data/secrets/shared/rclone-gdrive\" }}{{ .Data.data.secret_key }}{{ end }}"
}

env_template "RCLONE_AUTH_KEY" {
  contents = "\"{{ with secret \"kv/data/secrets/shared/rclone-gdrive\" }}{{ .Data.data.access_key }},{{ .Data.data.secret_key }}{{ end }}\""
}

# rclone は、`env -u` を通して起動する。Agent が OpenBao に出るための設定（SOCKS5 のプロキシ、
# OpenBao 向けの BAO_*）を、rclone に渡さないため。渡すと、Google Drive への通信まで、
# NetBird の SOCKS5 に流れて、失敗する。
#
# 待ち受けは2つ。
#   :10000           公開側（Render の入口）。段階 4 で、S3 を出さない形に変える
#   127.0.0.1:8210   NetBird 向け。NetBird の転送だけが、ここに届く（TLS なし。WireGuard で暗号化され、
#                    NetBird の ACL で、届く相手を絞っている）
exec {
  command = [
    "/usr/bin/env",
    "-u", "HTTPS_PROXY", "-u", "HTTP_PROXY", "-u", "NO_PROXY",
    "-u", "https_proxy", "-u", "http_proxy", "-u", "no_proxy",
    "-u", "BAO_ADDR", "-u", "BAO_CACERT", "-u", "BAO_TLS_SERVER_NAME", "-u", "BAO_CLIENT_TIMEOUT",
    "/bin/sh", "-c", "exec rclone serve s3 gdrive: --addr \":10000\" --addr \"127.0.0.1:8210\" --poll-interval 0"
  ]
  restart_on_secret_changes = "always"
}
