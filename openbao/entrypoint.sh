#!/bin/sh
set -e
umask 077

if [ -z "${OPENBAO_WRAPPED_TOKEN:-}" ]; then
  echo "OPENBAO_WRAPPED_TOKEN is not set" >&2
  exit 1
fi

# 公開側（Render の入口）は、S3 を出さない。ここに置くのは、次の2つだけ（render-ttyd のダミー nginx と、同じ役）。
#   ・ポートを開けておく（Render が、待ち受けを確認するため。無料プランの、スリープを避けるための、外からの通信の受け口にもなる）
#   ・/healthz（中身は空）。rclone の S3 が動いていて、NetBird に固定のピアで出ているときだけ、ファイルを置く。
#     watchdog は、これだけを見る（200 なら健全、404 なら中が壊れている、つながらない、5xx なら、コンテナが落ちている）。
# S3 は、NetBird 向けの 127.0.0.1:8210 だけで出す（openbao/agent.hcl）。
s3_alive() {
  for f in /proc/[0-9]*/cmdline; do
    tr '\0' ' ' < "$f" 2>/dev/null | grep -q '^rclone serve s3 ' && return 0
  done
  return 1
}
mkdir -p /tmp/empty
rclone serve http /tmp/empty --addr ":${PORT:-10000}" >/dev/null 2>&1 &
(
  while :; do
    if [ -e /tmp/nb/stable ] && s3_alive \
       && NB_DAEMON_ADDR=unix:///tmp/nb/netbird.sock netbird status 2>/dev/null | grep -qi "Management: Connected"; then
      : > /tmp/empty/healthz
    else
      rm -f /tmp/empty/healthz
    fi
    sleep 10
  done
) &

# 接続先:
#   OPENBAO_NB_ADDR     OpenBao の NetBird 側の宛先。例 https://100.74.x.y:8210（IP 指定。名前は引けない）
#   NB_SETUP_KEY        NetBird の使い捨てキー（Actions がデプロイのたびに作って、Render に渡す）。
#                       これで、仮のピアとして参加して、OpenBao に出る。固定のピアの設定（IP が変わらない。
#                       rclone を NetBird に出すのに必要）は、OpenBao の netbird_config_b64 から受け取って、切り替える
#   OPENBAO_PUBLIC_ADDR 公開側の宛先（移行中の、一時的な代替。段階 4 で、公開側を閉じたら、不要）
PUBLIC_ADDR="${OPENBAO_PUBLIC_ADDR:-https://openbao.jyrac.stki.org}"
NB_ADDR="${OPENBAO_NB_ADDR:-}"
NB_SNI="${OPENBAO_NB_SERVER_NAME:-openbao.netbird.cloud}"

export BAO_CLIENT_TIMEOUT=30s

VIA=""

use_public() {
  unset HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy BAO_CACERT BAO_TLS_SERVER_NAME
  export BAO_ADDR="$PUBLIC_ADDR"
  VIA=public
}

# NetBird 経由: SOCKS5（127.0.0.1:1080）に通し、ピン留めした証明書で、この名前を確認する。
use_netbird() {
  export HTTPS_PROXY=socks5://127.0.0.1:1080 https_proxy=socks5://127.0.0.1:1080
  export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
  export BAO_CACERT=/etc/openbao/ca.crt
  export BAO_TLS_SERVER_NAME="$NB_SNI"
  export BAO_ADDR="$NB_ADDR"
  VIA=netbird
}

NB_OK=0
if [ -n "$NB_ADDR" ] && [ -n "${NB_SETUP_KEY:-}" ]; then
  if /netbird-up.sh; then
    NB_OK=1
    use_netbird
  else
    echo "NB: NetBird に接続できませんでした。公開側の OpenBao に接続します（移行中の、一時的な代替）" >&2
  fi
fi
# キーは、もう使わない。rclone 本体の環境に残さない。
unset NB_SETUP_KEY
[ -n "$VIA" ] || use_public

unwrap() {
  bao unwrap -field=token "$OPENBAO_WRAPPED_TOKEN" 2>/tmp/unwrap.err
}

REAL_TOKEN=$(unwrap) || REAL_TOKEN=""
if [ -z "$REAL_TOKEN" ] && [ "$VIA" = "netbird" ]; then
  echo "NB: NetBird 経由の unwrap に失敗しました: $(tail -n 3 /tmp/unwrap.err | tr '\n' ' ')" >&2
  echo "NB: 公開側の OpenBao で、もう一度試します（移行中の、一時的な代替）" >&2
  use_public
  REAL_TOKEN=$(unwrap) || REAL_TOKEN=""
fi
if [ -z "$REAL_TOKEN" ]; then
  echo "unwrap failed: $(tail -n 3 /tmp/unwrap.err | tr '\n' ' ')" >&2
  exit 1
fi

printf '%s' "$REAL_TOKEN" > /tmp/vault-token

# Agent の接続設定（vault ブロック）は、経路によって変わるので、ここで作る。
# 証明書の1回発行（下）と、常駐の Agent（最後）の、両方が使う。
{
  echo 'vault {'
  echo "  address = \"$BAO_ADDR\""
  if [ "$VIA" = "netbird" ]; then
    echo '  ca_cert         = "/etc/openbao/ca.crt"'
    echo "  tls_server_name = \"$NB_SNI\""
  fi
  echo '}'
  echo
} > /tmp/vault.hcl

# S3 を HTTPS（TLS 1.3）で出すための、証明書と秘密鍵。
#   1. OpenBao の PKI（pki_int）から、起動のたびに、1回、発行する（openbao/cert-once.hcl。秘密鍵は、OpenBao に保存されない）。
#   2. 発行できなかったとき（PKI の不調、ポリシーなし、時間切れ）は、これまでの、kv の自己署名（tls_cert_pem / tls_key_pem）に戻る。
# どちらを使ったかは、ログの TLS_CERT_SOURCE=pki | kv-fallback で分かる。
# 1回発行の Agent は、失敗すると終わらずにリトライし続けるので、timeout で打ち切り、
# 成否は、終了コードではなく、ファイル（bundle.pem と key.pem）が、両方あるかで判断する。
mkdir -p /tmp/tls/pki
rm -f /tmp/tls/pki/bundle.pem /tmp/tls/pki/key.pem /tmp/tls/cert.pem /tmp/tls/key.pem

# 戻り先の kv の証明書は、先に受け取っておく（受け取れなくても、ここでは止めない）
BAO_TOKEN="$REAL_TOKEN" bao kv get -mount=kv -field=tls_cert_pem secrets/rclone/config > /tmp/tls/cert.pem 2>/tmp/tls.err || true
BAO_TOKEN="$REAL_TOKEN" bao kv get -mount=kv -field=tls_key_pem secrets/rclone/config > /tmp/tls/key.pem 2>>/tmp/tls.err || true

# 発行に失敗した理由を、ログから拾う（Agent の最後の行は、終了のメッセージだけなので、エラーの行を探す）
cert_once_why() {
  { grep -i -E 'error|denied|permission|refused|no such host|timeout' /tmp/cert-once.log || tail -n 3 /tmp/cert-once.log; } 2>/dev/null | tail -n 2 | tr '\n' ' '
}

if command -v timeout >/dev/null 2>&1; then
  cat /tmp/vault.hcl /etc/openbao/cert-once.hcl > /tmp/cert-once.hcl
  timeout 60 bao agent -config=/tmp/cert-once.hcl -exit-after-auth >/tmp/cert-once.log 2>&1 || true
else
  echo "TLS: timeout コマンドがありません。PKI からは発行せず、kv の自己署名を使います" >/tmp/cert-once.log
fi

if [ -s /tmp/tls/pki/bundle.pem ] && [ -s /tmp/tls/pki/key.pem ]; then
  cp /tmp/tls/pki/bundle.pem /tmp/tls/cert.pem
  cp /tmp/tls/pki/key.pem /tmp/tls/key.pem
  TLS_SRC=pki
elif [ -s /tmp/tls/cert.pem ] && [ -s /tmp/tls/key.pem ]; then
  TLS_SRC=kv-fallback
  echo "TLS: PKI から発行できませんでした。kv の自己署名を使います: $(cert_once_why)" >&2
else
  echo "TLS: PKI からも kv からも、証明書を受け取れません: $(cert_once_why) / $(tail -n 2 /tmp/tls.err | tr '\n' ' ')" >&2
  exit 1
fi
chmod 600 /tmp/tls/key.pem
rm -f /tmp/tls/pki/bundle.pem /tmp/tls/pki/key.pem /tmp/cert-once.hcl /tmp/cert-once.log
echo "TLS_CERT_SOURCE=$TLS_SRC"

# 証明書の期限と出どころを、公開側の /cert-info に出す（秘密ではない）。watchdog が、これを見て、
#   ・残りが 30 日を切ったら、再デプロイを起動して、新しく発行させる
#   ・出どころが pki 以外（kv-fallback）なら、警告を出す
if command -v openssl >/dev/null 2>&1; then
  NOT_AFTER=$(openssl x509 -in /tmp/tls/cert.pem -noout -enddate 2>/dev/null | sed 's/^notAfter=//') || NOT_AFTER=""
  if [ -n "$NOT_AFTER" ]; then
    printf 'source=%s\nnot_after=%s\n' "$TLS_SRC" "$NOT_AFTER" > /tmp/empty/cert-info
    echo "TLS_CERT_INFO source=$TLS_SRC not_after=$NOT_AFTER"
  fi
fi

# 固定のピアの設定を、OpenBao から受け取って、一時のピアから切り替える（unwrap と同じ経路を使う）。
# 受け取れない、または、切り替えに失敗したときは、一時のピアのまま続ける（OpenBao には出られるが、
# rclone は NetBird に出ない）。
if [ "$NB_OK" = 1 ]; then
  NB_CFG=$(BAO_TOKEN="$REAL_TOKEN" bao kv get -mount=kv -field=netbird_config_b64 secrets/rclone/config 2>/tmp/nbcfg.err) || NB_CFG=""
  if [ -n "$NB_CFG" ]; then
    NB_CONFIG_B64="$NB_CFG" /netbird-swap.sh || echo "NB: 固定のピアに切り替えられませんでした。rclone は NetBird に出ません" >&2
  else
    echo "NB: OpenBao から netbird_config_b64 を受け取れませんでした。rclone は NetBird に出ません: $(tail -n 2 /tmp/nbcfg.err | tr '\n' ' ')" >&2
  fi
  unset NB_CFG
fi

unset REAL_TOKEN OPENBAO_WRAPPED_TOKEN

# 常駐の Agent の設定は、vault ブロック（上で作った /tmp/vault.hcl）の後に、agent.hcl を続ける。
cat /tmp/vault.hcl /etc/openbao/agent.hcl > /tmp/agent.hcl

echo "OPENBAO_VIA=$VIA addr=$BAO_ADDR"
exec bao agent -config=/tmp/agent.hcl
