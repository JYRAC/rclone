#!/bin/sh
# NetBird（netstack）に参加する。このコンテナは、2つの役を兼ねる。
#   クライアント: OpenBao へ、SOCKS5（127.0.0.1:1080）経由で出る
#   サーバー    : NetBird の IP 宛ての通信を、localhost へ転送して、127.0.0.1:8210 の S3 を NetBird に出す
# サーバーとして、IP が変わらないことが必要なので、登録済みのピア設定を復元して、同じピアで復帰する
# （OpenBao と同じ方式）。成功したら 0、できなければ 1 を返す。ログには、キーを出さない。
#
#   NB_CONFIG_B64   登録済みのピア設定（base64）。あれば、登録せずに、同じピア・同じIPで復帰する
#   NB_SETUP_KEY    初回の登録だけ（使用回数1回、Ephemeral オフ）
#   NB_PRINT_CONFIG 1 のとき、ピア設定を base64 でログに1行出す（初回だけ。秘密鍵入り）
export NB_USE_NETSTACK_MODE=true
export NB_ENABLE_NETSTACK_LOCAL_FORWARDING=true
export NB_CONFIG=/tmp/nb/config.json
export NB_DAEMON_ADDR=unix:///tmp/nb/netbird.sock
export NB_LOG_FILE=console

mkdir -p /tmp/nb
chmod 700 /tmp/nb

mask() {
  if [ -n "${NB_SETUP_KEY:-}" ]; then sed "s|${NB_SETUP_KEY}|***|g"; else cat; fi
}

RESTORED=0
if [ -n "${NB_CONFIG_B64:-}" ]; then
  if ( umask 077; printf '%s' "$NB_CONFIG_B64" | base64 -d > "$NB_CONFIG" ) 2>/dev/null && [ -s "$NB_CONFIG" ]; then
    RESTORED=1
    echo "NB: ピア設定を復元しました"
  else
    echo "NB: NB_CONFIG_B64 を読めません" >&2
  fi
fi

if [ "$RESTORED" != 1 ] && [ -z "${NB_SETUP_KEY:-}" ]; then
  echo "NB: NB_CONFIG_B64 も NB_SETUP_KEY も無いため、NetBird には参加しません" >&2
  exit 1
fi

netbird service run > /tmp/nb/service.log 2>&1 &

# 常駐プロセスの起動待ち（最大30秒）
i=0
while [ "$i" -lt 30 ]; do
  netbird status >/dev/null 2>&1 && break
  i=$((i + 1))
  sleep 1
done

if [ "$RESTORED" = 1 ]; then
  if ! netbird up --hostname "${NB_HOSTNAME:-rclone}" > /tmp/nb/up.log 2>&1; then
    echo "NB: netbird up（復元）に失敗しました:" >&2
    tail -n 5 /tmp/nb/up.log | mask >&2
    exit 1
  fi
else
  if ! netbird up --setup-key "$NB_SETUP_KEY" --hostname "${NB_HOSTNAME:-rclone}" > /tmp/nb/up.log 2>&1; then
    echo "NB: netbird up（初回登録）に失敗しました:" >&2
    tail -n 5 /tmp/nb/up.log | mask >&2
    exit 1
  fi
fi

# 接続待ち（最大40秒）
i=0
OK=0
while [ "$i" -lt 40 ]; do
  if netbird status 2>/dev/null | grep -qi "Management: Connected"; then OK=1; break; fi
  i=$((i + 1))
  sleep 1
done

if [ "$OK" != 1 ]; then
  echo "NB: 接続の確認が、時間切れになりました" >&2
  tail -n 5 /tmp/nb/service.log | mask >&2
  exit 1
fi

echo "NB: connected ip=$(netbird status --ipv4 2>/dev/null || echo unknown) hostname=${NB_HOSTNAME:-rclone}"

if [ "${NB_PRINT_CONFIG:-0}" = "1" ]; then
  if [ -s "$NB_CONFIG" ]; then
    echo "NB_CONFIG_B64=$(base64 "$NB_CONFIG" | tr -d '\n')"
  else
    echo "NB: NB_PRINT_CONFIG=1 ですが、$NB_CONFIG がありません" >&2
  fi
fi
exit 0
