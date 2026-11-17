# 起動時に1回だけ、S3 のサーバー証明書を、OpenBao の PKI（pki_int）から発行する（entrypoint.sh が呼ぶ）。
# 秘密鍵は、OpenBao に保存されない（このコンテナの中で受け取って、ファイルに書くだけ）。
#
#   ・ロール rclone は、rclone.netbird.cloud だけを発行できる（OpenBao 側の設定）。
#     必要なポリシー pki-issue-rclone は、JWT ロール rclone の token_policies に足してある
#   ・bundle.pem は、葉 + 中間 CA の連結。rclone が、そのまま、フルチェーンとして送る。
#     クライアント（Directus の中継）は、ルート CA だけで検証する
#   ・有効期間は 2160h（90日、ロールの最長）。この証明書は、再デプロイのたびに、新しくなる。
#     期限が近づいたら、watchdog が、再デプロイを起動する（公開側の /cert-info を見る）
#
# 失敗すると（権限がない、OpenBao に届かない）、Agent は終わらずに、リトライし続ける。
# だから、呼ぶ側（entrypoint.sh）は、必ず timeout で打ち切り、成否は、ファイルの有無で判断する。

auto_auth {
  method {
    type = "token_file"
    config = {
      token_file_path = "/tmp/vault-token"
    }
  }
}

template_config {
  exit_on_retry_failure = true
}

template {
  destination = "/tmp/tls/pki/bundle.pem"
  perms       = "0600"
  contents    = <<EOC
{{ with pkiCert "pki_int/issue/rclone" "common_name=rclone.netbird.cloud" "ttl=2160h" }}{{ .Cert }}{{ .CA }}
{{ .Key | writeToFile "/tmp/tls/pki/key.pem" "" "" "0600" }}{{ end }}
EOC
}
