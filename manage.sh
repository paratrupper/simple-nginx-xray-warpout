#!/usr/bin/env bash
# shellcheck disable=SC2016
# =============================================================================
#  xray-manage — small runtime operations for simple-nginx-xray-warpout
#  usage: xray-manage status|links|user ...|warp on|off|restart
# =============================================================================
set -Eeuo pipefail

STATE_FILE="/etc/xray-installer/state.json"
XRAY_CONF="/usr/local/etc/xray/config.json"
WARP_DIR="/etc/xray-installer/warp"

DOMAIN=""
PUBLIC_KEY=""
SHORT_ID=""
ENDPOINT=""
TRANSPORT="tcp"
GRPC_SERVICE=""
XHTTP_PATH=""
MUX="false"
WARP="all"
TCP_PORT=0
TCP_UUID=""

die() { echo "xray-manage: $*" >&2; exit 1; }
ok()  { echo "ok: $*"; }

usage() {
  cat <<'USAGE'
xray-manage — runtime operations for simple-nginx-xray-warpout

  xray-manage status
  xray-manage links
  xray-manage user list
  xray-manage user add <name>
  xray-manage user del <name|uuid>
  xray-manage warp on
  xray-manage warp off
  xray-manage restart
USAGE
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
}

require_state() {
  require_root
  [[ -f $STATE_FILE ]] || die "no installation found ($STATE_FILE)"
  [[ -f $XRAY_CONF ]] || die "missing $XRAY_CONF"
  command -v jq >/dev/null || die "jq is required"
}

load_state() {
  DOMAIN=$(jq -r '.domain // empty' "$STATE_FILE")
  PUBLIC_KEY=$(jq -r '.public_key // empty' "$STATE_FILE")
  SHORT_ID=$(jq -r '.short_id // empty' "$STATE_FILE")
  ENDPOINT=$(jq -r '.endpoint // empty' "$STATE_FILE")
  TRANSPORT=$(jq -r '.transport // "tcp"' "$STATE_FILE")
  GRPC_SERVICE=$(jq -r '.grpc_service // empty' "$STATE_FILE")
  XHTTP_PATH=$(jq -r '.xhttp_path // empty' "$STATE_FILE")
  MUX=$(jq -r '.mux // false' "$STATE_FILE")
  WARP=$(jq -r '.warp // "all"' "$STATE_FILE")
  TCP_PORT=$(jq -r '.tcp_port // 0' "$STATE_FILE")
  TCP_UUID=$(jq -r '.tcp_uuid // empty' "$STATE_FILE")
}

link_host() {
  local h=$1
  if [[ $h == *:* && $h != \[* ]]; then
    printf '[%s]' "$h"
  else
    printf '%s' "$h"
  fi
}

make_link() {
  local host=$1 id=$2 flow="" type="type=tcp" enc
  case "$TRANSPORT" in
    grpc)
      type="type=grpc&serviceName=$GRPC_SERVICE" ;;
    xhttp)
      enc=${XHTTP_PATH//\//%2F}
      type="type=xhttp&path=$enc&host=$DOMAIN&mode=stream-up" ;;
    tcp)
      [[ $MUX == "true" ]] || flow="&flow=xtls-rprx-vision" ;;
  esac
  printf 'vless://%s@%s:443?encryption=none%s&security=reality&sni=%s&fp=firefox&pbk=%s&sid=%s&%s#%s\n' \
    "$id" "$(link_host "$host")" "$flow" "$DOMAIN" "$PUBLIC_KEY" "$SHORT_ID" "$type" "$DOMAIN"
}

make_tcp_link() {
  local host=$1
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=firefox&pbk=%s&sid=%s&type=tcp#%s-tcp\n' \
    "$TCP_UUID" "$(link_host "$host")" "$TCP_PORT" "$DOMAIN" "$PUBLIC_KEY" "$SHORT_ID" "$DOMAIN"
}

fix_xray_perms() {
  local user grp
  user=$(systemctl show -p User --value xray 2>/dev/null || true)
  [[ -n $user ]] || user="root"
  grp=$(systemctl show -p Group --value xray 2>/dev/null || true)
  [[ -n $grp ]] || grp=$(id -gn "$user" 2>/dev/null || echo root)
  chown root:"$grp" /usr/local/etc/xray "$XRAY_CONF" 2>/dev/null || true
  chmod 750 /usr/local/etc/xray
  chmod 640 "$XRAY_CONF"
}

restart_xray() {
  xray run -test -c "$XRAY_CONF" >/dev/null 2>&1 || die "config test failed"
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray || die "xray failed to restart"
}

edit_config() {
  # edit_config <jq-args...> -- <filter>
  local tmp="$XRAY_CONF.tmp.json"
  local backup="$XRAY_CONF.bak.$$"
  cp -a "$XRAY_CONF" "$backup"

  local filter="${!#}"
  local args=("${@:1:$#-1}")
  if ! jq "${args[@]}" "$filter" "$XRAY_CONF" > "$tmp"; then
    rm -f "$tmp" "$backup"
    die "jq failed"
  fi

  local out
  if ! out=$(xray run -test -config "$tmp" 2>&1); then
    rm -f "$tmp" "$backup"
    die "config test failed: $out"
  fi

  mv "$tmp" "$XRAY_CONF"
  fix_xray_perms
  rm -f "$backup"
}

print_links() {
  local name id
  while IFS=$'\t' read -r name id; do
    [[ -n $id ]] || continue
    echo "--- ${name:-user} ---"
    make_link "$ENDPOINT" "$id"
    printf '\n'
  done < <(jq -r '.inbounds[0].settings.clients[] | [(.email // "user"), .id] | @tsv' "$XRAY_CONF")
  if [[ ${TCP_PORT:-0} -gt 0 && $TRANSPORT != "tcp" ]]; then
    echo "--- tcp fallback :$TCP_PORT ---"
    make_tcp_link "$ENDPOINT"
    if getent ahostsv6 "$DOMAIN" >/dev/null 2>&1; then
      make_tcp_link "$DOMAIN"
    fi
    printf '\n'
  fi
}

cmd_status() {
  require_state
  load_state

  echo "--- state ---"
  jq 'del(.private_key)' "$STATE_FILE"
  echo "--- services ---"
  systemctl is-active xray nginx 2>/dev/null || true
  echo "--- listeners ---"
  ss -lntp 2>/dev/null | grep -E ":(80|443|8443|${TCP_PORT})\\b" || true
  echo "--- certificate ---"
  local cert
  cert=$(jq -r '.cert // empty' "$STATE_FILE")
  if [[ -n $cert && -f $cert ]]; then
    openssl x509 -in "$cert" -noout -subject -issuer -enddate 2>/dev/null || true
  else
    echo "not found"
  fi
  echo "--- xray test ---"
  if xray run -test -c "$XRAY_CONF" >/dev/null 2>&1; then echo ok; else echo failed; fi
}

cmd_links() {
  require_state
  load_state
  print_links
}

cmd_user_list() {
  require_state
  load_state
  jq -r '.inbounds[0].settings.clients[] | "\(.email // "user")\t\(.id)"' "$XRAY_CONF"
}

cmd_user_add() {
  require_state
  load_state
  local name="${1:-}" count id flowval="" net
  count=$(jq '.inbounds[0].settings.clients | length' "$XRAY_CONF")
  [[ -n $name ]] || name="user$((count + 1))"
  if jq -e --arg e "$name" \
       '.inbounds[0].settings.clients[] | select((.email // "") == $e)' \
       "$XRAY_CONF" >/dev/null 2>&1; then
    die "user '$name' already exists"
  fi
  id=$(xray uuid)
  net=$(jq -r '.inbounds[0].streamSettings.network // "tcp"' "$XRAY_CONF")
  if [[ $net == "tcp" && $MUX != "true" ]]; then flowval="xtls-rprx-vision"; fi

  edit_config --arg id "$id" --arg email "$name" --arg flow "$flowval" \
    '.inbounds[0].settings.clients += [({id:$id, email:$email} + (if $flow != "" then {flow:$flow} else {} end))]'
  restart_xray
  ok "user $name added"
  make_link "$ENDPOINT" "$id"
}

cmd_user_del() {
  require_state
  load_state
  local key="${1:-}" before after
  [[ -n $key ]] || die "usage: xray-manage user del <name|uuid>"
  before=$(jq '.inbounds[0].settings.clients | length' "$XRAY_CONF")
  edit_config --arg k "$key" \
    '.inbounds[0].settings.clients |= map(select((.email // "") != $k and .id != $k))'
  after=$(jq '.inbounds[0].settings.clients | length' "$XRAY_CONF")
  [[ $after -lt $before ]] || die "user not found: $key"
  restart_xray
  ok "user $key removed (${after} left)"
  if [[ $after -eq 0 ]]; then
    echo "warning: no users left; nobody can connect" >&2
  fi
}

parse_warp() {
  local p="$WARP_DIR/wgcf-profile.conf" a="$WARP_DIR/wgcf-account.toml" cid
  [[ -f $p ]] || return 1
  WG_PRIV=$(awk -F' *= *' '/^PrivateKey/{print $2; exit}' "$p")
  WG_PUB=$(awk -F' *= *' '/^PublicKey/{print $2; exit}' "$p")
  WG_ENDPOINT=$(awk -F' *= *' '/^Endpoint/{print $2; exit}' "$p")
  WG_V4=$(awk -F' *= *' '/^Address/ && $2 ~ /\./ {print $2; exit}' "$p")
  WG_V6=$(awk -F' *= *' '/^Address/ && $2 ~ /:/ {print $2; exit}' "$p")
  [[ -n $WG_PRIV && -n $WG_PUB && -n $WG_ENDPOINT && -n $WG_V4 && -n $WG_V6 ]] || return 1
  WG_V4=${WG_V4%%/*}
  WG_V6=${WG_V6%%/*}

  WG_RESERVED="[0,0,0]"
  if [[ -f $a ]]; then
    cid=$(awk -F'"' '/client_id/{print $2; exit}' "$a" || true)
    if [[ -n $cid ]]; then
      WG_RESERVED=$(python3 - "$cid" <<'PY'
import base64, json, sys
try:
    raw = base64.b64decode(sys.argv[1].rstrip("=") + "===")
    print(json.dumps(list(raw[:3])))
except Exception:
    print("[0,0,0]")
PY
)
    fi
  fi
  return 0
}

cmd_warp_on() {
  require_state
  load_state
  [[ $WARP != "all" ]] || { ok "WARP is already on"; return 0; }
  parse_warp || die "no WARP profile in $WARP_DIR; reinstall with --warp all"

  local wg
  wg=$(jq -n \
    --arg k "$WG_PRIV" --arg p "$WG_PUB" --arg e "$WG_ENDPOINT" \
    --arg a4 "$WG_V4" --arg a6 "$WG_V6" --argjson r "$WG_RESERVED" \
    '{tag:"warp", protocol:"wireguard", settings:{
      secretKey:$k, address:[$a4,$a6],
      peers:[{publicKey:$p, endpoint:$e}],
      reserved:$r, noKernelTun:true, mtu:1280}}') || die "cannot build WARP outbound"

  edit_config --argjson wg "$wg" '
    .outbounds = ([$wg] + (.outbounds | map(select(.tag != "warp"))))
    | .routing.balancers = [{tag:"warp-balancer", selector:["warp"], fallbackTag:"direct", strategy:{type:"leastPing"}}]
    | .observatory = {subjectSelector:["warp"], probeUrl:"https://www.cloudflare.com/cdn-cgi/trace", probeInterval:"60s"}
    | .routing.rules = (.routing.rules | map(
        if (.network == "tcp,udp") and ((has("outboundTag")) or (has("balancerTag")))
        then {type:"field", network:"tcp,udp", balancerTag:"warp-balancer"} else . end))
  '
  restart_xray
  jq '.warp = "all"' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  ok "WARP enabled"
}
cmd_warp_off() {
  require_state
  load_state
  [[ $WARP == "all" ]] || { ok "WARP is already off"; return 0; }

  edit_config '
    .outbounds = (.outbounds | map(select(.tag != "warp")))
    | del(.routing.balancers)
    | del(.observatory)
    | .routing.rules = (.routing.rules | map(
        if (.network == "tcp,udp") and ((has("outboundTag")) or (has("balancerTag")))
        then {type:"field", network:"tcp,udp", outboundTag:"direct"} else . end))
  '
  restart_xray
  jq '.warp = "off"' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  ok "WARP disabled (direct)"
}

cmd_restart() {
  require_state
  restart_xray
  ok "xray restarted"
}

# --------------------------------------------------------------------- main --

cmd="${1:-}"
case "$cmd" in
  status)   cmd_status ;;
  links)    cmd_links ;;
  restart)  cmd_restart ;;
  user)
    shift
    case "${1:-}" in
      list) cmd_user_list ;;
      add)  shift; cmd_user_add "${1:-}" ;;
      del)  shift; cmd_user_del "${1:-}" ;;
      *)    usage; exit 1 ;;
    esac ;;
  warp)
    shift
    case "${1:-}" in
      on)  cmd_warp_on ;;
      off) cmd_warp_off ;;
      *)   usage; exit 1 ;;
    esac ;;
  ""|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
