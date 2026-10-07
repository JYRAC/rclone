vault {
  address = "https://openbao.jyrac.stki.org"
}

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

exec {
  command                   = ["/bin/sh", "-c", "exec rclone serve s3 gdrive: --addr \":10000\" --poll-interval 0 --auth-key \"${RCLONE_S3_ACCESS_KEY},${RCLONE_S3_SECRET_KEY}\""]
  restart_on_secret_changes = "always"
}