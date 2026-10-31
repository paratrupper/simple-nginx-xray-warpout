#!/usr/bin/env bash
# =============================================================================
#  simple-nginx-xray-warpout
#  VLESS + REALITY (self-steal) + nginx decoy + optional Cloudflare WARP
#
#  Target : Ubuntu 22.04, systemd, root
#  Ports  : 443/tcp — Xray (REALITY), 80/tcp — nginx, 127.0.0.1:8443 — nginx TLS
# =============================================================================
set -Eeuo pipefail

APP_NAME="simple-nginx-xray-warpout"
APP_VERSION="1.2.0"

STATE_DIR="/etc/xray-installer"
STATE_FILE="$STATE_DIR/state.json"
BACKUP_ROOT="/var/backups/xray-installer"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONF="$XRAY_DIR/config.json"
NGINX_SITES="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
WWW_ROOT="/var/www"
LE_ROOT="/etc/letsencrypt/live"
LOG_FILE="/var/log/xray-installer.log"

DOMAIN=""
EMAIL=""
ENDPOINT=""
WARP="all"
BLOCK_RU=1
CERT_METHOD="http"
CF_TOKEN=""
SSH_PORT="22"
FORCE=0
REGEN_KEYS=0
NONINTERACTIVE=0
DO_QR=0
MUX=0
MUX_SET=0
TRANSPORT="tcp"
TRANSPORT_SET=0
GRPC_SERVICE=""
ACTION="install"
ADD_USER_NAME=""

UUID_VALUE=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
CERT_CRT=""
CERT_KEY=""
WG_PRIV=""
WG_PUB=""
WG_ENDPOINT=""
WG_V4=""
WG_V6=""
WG_RESERVED="[0,0,0]"
DECOY_NAME="Northwind Studio"

if [[ -t 1 ]]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
  C_BLU=$'\033[1;34m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_OFF=""
fi

log()  { printf '%s[%s]%s %s\n' "$C_BLU" "$(date +%H:%M:%S)" "$C_OFF" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s  xx%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

on_error() {
  local code=$?
  printf '%s  xx failed at line %s (exit %s)%s\n' "$C_RED" "$1" "$code" "$C_OFF" >&2
  printf '     see %s\n' "$LOG_FILE" >&2
  exit "$code"
}
trap 'on_error $LINENO' ERR

usage() {
  cat <<'USAGE'
simple-nginx-xray-warpout — VLESS+REALITY installer (self-steal, nginx decoy, WARP)

Usage:
  bash install.sh [--domain example.com] [--email you@example.com] [options]
  bash install.sh --add-user [name]
  bash install.sh --links | --status | --uninstall
  bash install.sh --enable-mux | --disable-mux

Options:
  --domain NAME          domain for SNI / serverNames / certificate (asked if omitted)
  --email ADDR           Let's Encrypt account email (asked if omitted)
  --endpoint HOST        address used in the client link (default: detected IPv6)
  --warp all|off         route all traffic through Cloudflare WARP (default all)
  --transport tcp|grpc   tcp = Vision (default), grpc = HTTP/2 multiplexing (works with sing-box)
  --service-name NAME    gRPC service name (generated automatically for grpc)
  --block-ru             block .ru/.xn--p1ai/.su and geoip:ru (default)
  --no-block-ru          do not block Russian destinations
  --cert-method http|dns|none   certificate source (default http)
  --cf-token TOKEN       Cloudflare API token for DNS-01
  --ssh-port PORT        SSH port to keep open in the firewall (default 22)
  --qr                   print a QR code for the client link
  --mux                  drop Vision and allow client-side Mux.Cool (fewer TCP connections)
  --regen-keys           generate a new UUID / Reality keypair / shortId
  --force                reinstall over an existing setup
  --non-interactive      never prompt
  -h, --help             this help

Examples:
  bash install.sh --domain v.example.com --email me@example.com --warp off
  bash install.sh --add-user phone
  bash install.sh --links
USAGE
}

# ---------------------------------------------------------------- utilities --

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root (sudo -i)"
}

have_tty() {
  [[ -r /dev/tty ]] && ( : < /dev/tty ) 2>/dev/null
}

port_listening() {
  local out
  out=$(ss -lntH 2>/dev/null | awk -v port=":$1" '$4 ~ (port "$")') || true
  [[ -n $out ]]
}

backup_file() {
  local f=$1 dir
  [[ -e $f ]] || return 0
  dir="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  cp -a "$f" "$dir/" 2>/dev/null || true
  printf '%s\n' "$dir" > "$STATE_DIR/last-backup"
}

detect_ipv6() {
  ip -6 addr show scope global 2>/dev/null \
    | awk '/inet6/ {print $2}' \
    | cut -d/ -f1 \
    | grep -E '^[23]' \
    | head -n1
}

normalize_domain() {
  local d=$1
  d=${d#http://}; d=${d#https://}; d=${d%%/*}; d=${d,,}; d=${d%.}
  printf '%s' "$d"
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
  local host=$1 uuid=$2 flowparam="" typeparam="type=tcp"
  if [[ $TRANSPORT == "grpc" ]]; then
    typeparam="type=grpc&serviceName=$GRPC_SERVICE"
  elif [[ $MUX -eq 0 ]]; then
    flowparam="&flow=xtls-rprx-vision"
  fi
  printf 'vless://%s@%s:443?encryption=none%s&security=reality&sni=%s&fp=firefox&pbk=%s&sid=%s&%s#%s\n' \
    "$uuid" "$(link_host "$host")" "$flowparam" "$DOMAIN" "$PUBLIC_KEY" "$SHORT_ID" "$typeparam" "$DOMAIN"
}

# --------------------------------------------------------------- arg parse --

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)        [[ $# -ge 2 ]] || die "--domain needs a value"; DOMAIN=$2; shift 2 ;;
    --email)         [[ $# -ge 2 ]] || die "--email needs a value"; EMAIL=$2; shift 2 ;;
    --endpoint)      [[ $# -ge 2 ]] || die "--endpoint needs a value"; ENDPOINT=$2; shift 2 ;;
    --warp)          [[ $# -ge 2 ]] || die "--warp needs a value"; WARP=$2; shift 2 ;;
    --block-ru)      BLOCK_RU=1; shift ;;
    --no-block-ru)   BLOCK_RU=0; shift ;;
    --cert-method)   [[ $# -ge 2 ]] || die "--cert-method needs a value"; CERT_METHOD=$2; shift 2 ;;
    --cf-token)      [[ $# -ge 2 ]] || die "--cf-token needs a value"; CF_TOKEN=$2; shift 2 ;;
    --ssh-port)      [[ $# -ge 2 ]] || die "--ssh-port needs a value"; SSH_PORT=$2; shift 2 ;;
    --qr)            DO_QR=1; shift ;;
    --mux)           MUX=1; MUX_SET=1; shift ;;
    --transport)     [[ $# -ge 2 ]] || die "--transport needs a value"; TRANSPORT=$2; TRANSPORT_SET=1; shift 2 ;;
    --service-name)  [[ $# -ge 2 ]] || die "--service-name needs a value"; GRPC_SERVICE=$2; shift 2 ;;
    --enable-mux)    ACTION="enable-mux"; shift ;;
    --disable-mux)   ACTION="disable-mux"; shift ;;
    --regen-keys)    REGEN_KEYS=1; shift ;;
    --force)         FORCE=1; shift ;;
    --non-interactive) NONINTERACTIVE=1; shift ;;
    --add-user)      ACTION="add-user"; shift
                     if [[ $# -gt 0 && $1 != --* ]]; then ADD_USER_NAME=$1; shift; fi ;;
    --links)         ACTION="links"; shift ;;
    --status)        ACTION="status"; shift ;;
    --uninstall)     ACTION="uninstall"; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown option: $1 (try --help)" ;;
  esac
done

case "$WARP" in all|off) ;; *) die "--warp must be all or off" ;; esac
case "$CERT_METHOD" in http|dns|none) ;; *) die "--cert-method must be http, dns or none" ;; esac
case "$TRANSPORT" in tcp|grpc) ;; *) die "--transport must be tcp or grpc" ;; esac
if [[ $MUX -eq 1 && $TRANSPORT == "grpc" ]]; then
  die "--mux is only for tcp; gRPC already multiplexes"
fi
[[ $SSH_PORT =~ ^[0-9]+$ ]] || die "--ssh-port must be numeric"

# ------------------------------------------------------------------ install --

preflight_os() {
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ ${ID:-} != "ubuntu" ]]; then
    warn "tested on Ubuntu 22.04; found ${PRETTY_NAME:-unknown}"
  elif [[ ${VERSION_ID:-} != "22.04" ]]; then
    warn "tested on Ubuntu 22.04; found ${VERSION_ID}"
  fi
  command -v systemctl >/dev/null || die "systemd is required"
}

ensure_packages() {
  log "installing packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    curl ca-certificates jq openssl unzip nginx certbot ufw iproute2 \
    >>"$LOG_FILE" 2>&1 || die "apt-get install failed (see $LOG_FILE)"
  systemctl enable --now nginx >/dev/null 2>&1 || true
  if [[ $DO_QR -eq 1 ]]; then
    apt-get install -y -qq qrencode >>"$LOG_FILE" 2>&1 || warn "qrencode not installed"
  fi
}

load_state() {
  [[ -f $STATE_FILE ]] || return 0
  command -v jq >/dev/null || return 0
  local v
  v=$(jq -r '.domain // empty' "$STATE_FILE" 2>/dev/null || true)
  [[ -n $v && -z $DOMAIN ]] && DOMAIN=$v
  if [[ $REGEN_KEYS -eq 0 ]]; then
    v=$(jq -r '.uuid // empty' "$STATE_FILE" 2>/dev/null || true);        [[ -n $v && -z $UUID_VALUE ]] && UUID_VALUE=$v
    v=$(jq -r '.private_key // empty' "$STATE_FILE" 2>/dev/null || true); [[ -n $v && -z $PRIVATE_KEY ]] && PRIVATE_KEY=$v
    v=$(jq -r '.public_key // empty' "$STATE_FILE" 2>/dev/null || true);  [[ -n $v && -z $PUBLIC_KEY ]] && PUBLIC_KEY=$v
    v=$(jq -r '.short_id // empty' "$STATE_FILE" 2>/dev/null || true);    [[ -n $v && -z $SHORT_ID ]] && SHORT_ID=$v
  fi
  v=$(jq -r '.endpoint // empty' "$STATE_FILE" 2>/dev/null || true)
  [[ -n $v && -z $ENDPOINT ]] && ENDPOINT=$v
  load_transport_state
  load_mux_state
  return 0
}

collect_params() {
  if [[ -z $DOMAIN ]]; then
    if [[ $NONINTERACTIVE -eq 1 ]] || ! have_tty; then
      die "--domain is required (no terminal to prompt)"
    fi
    read -rp "Domain (SNI, must resolve to this server): " DOMAIN < /dev/tty \
      || die "no input"
  fi
  DOMAIN=$(normalize_domain "$DOMAIN")
  [[ $DOMAIN =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9-]{2,}$ ]] || die "invalid domain: $DOMAIN"

  if [[ -z $EMAIL ]]; then
    EMAIL="admin@$DOMAIN"
    if [[ $NONINTERACTIVE -eq 0 ]] && have_tty; then
      read -rp "Email for Let's Encrypt [$EMAIL]: " _email < /dev/tty || true
      [[ -n ${_email:-} ]] && EMAIL=$_email
    fi
  fi

  if [[ -z $ENDPOINT ]]; then
    ENDPOINT=$(detect_ipv6 || true)
  fi
  [[ -n $ENDPOINT ]] || die "no global IPv6 address found; pass --endpoint"
  ENDPOINT=${ENDPOINT#\[}; ENDPOINT=${ENDPOINT%\]}

  if [[ $TRANSPORT == "grpc" && -z $GRPC_SERVICE ]]; then
    GRPC_SERVICE="Gun$(openssl rand -hex 6)"
  fi
  if [[ $TRANSPORT == "grpc" ]]; then
    MUX=0
  fi

  ok "domain: $DOMAIN"
  ok "endpoint: $ENDPOINT"
  ok "transport: $TRANSPORT${GRPC_SERVICE:+ ($GRPC_SERVICE)}"
}

check_ports() {
  local p443 addrs
  p443=$(ss -lntpH -p 2>/dev/null | awk '$4 ~ /:443$/') || true
  if [[ -n $p443 ]] && ! grep -q 'xray' <<<"$p443"; then
    die "port 443 is already in use: $p443"
  fi
  addrs=$(ss -lntH 2>/dev/null | awk '{print $4}') || true
  grep -qE "[:.]${SSH_PORT}$" <<<"$addrs" || die "sshd is not listening on port $SSH_PORT; pass --ssh-port"
}

check_dns() {
  local pub4 a_rec aaaa_rec
  pub4=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
  a_rec=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
  aaaa_rec=$(getent ahostsv6 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')

  if [[ -z $a_rec && -z $aaaa_rec ]]; then
    warn "domain $DOMAIN does not resolve yet; HTTP-01 will fail without an A/AAAA record"
  fi
  if [[ -n $a_rec && -n $pub4 && $a_rec != "$pub4" ]]; then
    warn "A for $DOMAIN is $a_rec, but this server's IPv4 is $pub4; HTTP-01 may fail (Cloudflare proxy?)"
  fi
  if [[ -z $aaaa_rec ]]; then
    warn "AAAA for $DOMAIN is not visible yet; the IPv6 client link uses the literal address"
  fi
  return 0
}

setup_sysctl() {
  log "applying sysctl"
  cat > /etc/sysctl.d/99-xray.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 65535
net.ipv4.tcp_fastopen = 3
net.ipv4.ip_local_port_range = 10000 65000
net.ipv6.bindv6only = 0
fs.file-max = 1000000
EOF
  modprobe tcp_bbr 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || warn "sysctl reload returned an error"
}

setup_firewall() {
  log "configuring firewall"
  command -v ufw >/dev/null || { warn "ufw not found, skipping"; return 0; }
  ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  if [[ -f /etc/default/ufw ]]; then
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
  fi
  ufw --force enable >/dev/null 2>&1 || warn "could not enable ufw"
}

write_decoy() {
  mkdir -p "$WWW_ROOT/$DOMAIN/.well-known/acme-challenge"
  chmod 755 "$WWW_ROOT/$DOMAIN" "$WWW_ROOT/$DOMAIN/.well-known" "$WWW_ROOT/$DOMAIN/.well-known/acme-challenge"

  cat > "$WWW_ROOT/$DOMAIN/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Northwind Studio — product design and engineering</title>
<style>
  :root { --ink:#12161c; --muted:#5b6673; --line:#e4e8ee; --accent:#2f6df6; }
  * { box-sizing:border-box; }
  body { margin:0; font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; color:var(--ink); background:#fff; }
  .wrap { max-width:960px; margin:0 auto; padding:0 24px; }
  header { border-bottom:1px solid var(--line); }
  header .wrap { display:flex; align-items:center; justify-content:space-between; height:72px; }
  .brand { font-weight:700; letter-spacing:-.02em; font-size:18px; }
  nav a { color:var(--muted); text-decoration:none; margin-left:28px; font-size:14px; }
  nav a:hover { color:var(--ink); }
  main { padding:96px 0 72px; }
  h1 { font-size:clamp(32px,5vw,52px); line-height:1.1; letter-spacing:-.03em; margin:0 0 20px; }
  .lead { font-size:19px; color:var(--muted); max-width:640px; margin:0 0 40px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(240px,1fr)); gap:32px; margin-top:56px; }
  .card h3 { margin:0 0 8px; font-size:16px; }
  .card p { margin:0; color:var(--muted); font-size:15px; }
  footer { border-top:1px solid var(--line); padding:32px 0; color:var(--muted); font-size:14px; }
  .btn { display:inline-block; background:var(--accent); color:#fff; text-decoration:none; padding:12px 22px; border-radius:8px; font-weight:600; font-size:15px; }
</style>
</head>
<body>
<header><div class="wrap">
  <div class="brand">Northwind Studio</div>
  <nav><a href="#work">Work</a><a href="#about">About</a><a href="#contact">Contact</a></nav>
</div></header>
<main><div class="wrap">
  <h1>Product design and engineering for teams that ship.</h1>
  <p class="lead">We are a small studio helping founders and product teams turn rough ideas into reliable, well-crafted software.</p>
  <a class="btn" href="#contact">Start a project</a>
  <div class="grid" id="work">
    <div class="card"><h3>Product strategy</h3><p>Discovery, scoping and roadmaps that keep engineering focused on what matters.</p></div>
    <div class="card"><h3>Interface design</h3><p>Design systems, prototypes and production-ready UI for web and mobile.</p></div>
    <div class="card"><h3>Engineering</h3><p>Backend, frontend and infrastructure delivered as one coherent product.</p></div>
  </div>
</div></main>
<footer><div class="wrap" id="contact">Northwind Studio · hello@northwind.example · Berlin</div></footer>
</body>
</html>
HTML

  cat > "$WWW_ROOT/$DOMAIN/robots.txt" <<'TXT'
User-agent: *
Allow: /
TXT
}

setup_nginx_http() {
  log "configuring nginx (port 80)"
  write_decoy
  backup_file "$NGINX_SITES/$DOMAIN.conf"
  mkdir -p "$NGINX_SITES" "$NGINX_ENABLED"
  cat > "$NGINX_SITES/$DOMAIN.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    root $WWW_ROOT/$DOMAIN;
    index index.html;

    location /.well-known/acme-challenge/ {
        root $WWW_ROOT/$DOMAIN;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
  ln -sf "$NGINX_SITES/$DOMAIN.conf" "$NGINX_ENABLED/$DOMAIN.conf"
  nginx -t >>"$LOG_FILE" 2>&1 || die "nginx config test failed"
  systemctl reload nginx
}

self_signed_cert() {
  warn "issuing a self-signed certificate (browsers will show a warning)"
  CERT_CRT="/etc/ssl/certs/$DOMAIN.crt"
  CERT_KEY="/etc/ssl/private/$DOMAIN.key"
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "$CERT_KEY" -out "$CERT_CRT" \
    -subj "/CN=$DOMAIN" >>"$LOG_FILE" 2>&1
  chmod 600 "$CERT_KEY"
}

issue_cert() {
  CERT_CRT="$LE_ROOT/$DOMAIN/fullchain.pem"
  CERT_KEY="$LE_ROOT/$DOMAIN/privkey.pem"
  if [[ -f $CERT_CRT && -f $CERT_KEY ]]; then
    ok "certificate already present"
    return 0
  fi

  case "$CERT_METHOD" in
    none)
      die "certificate not found at $CERT_CRT (--cert-method none)" ;;
    dns)
      [[ -n $CF_TOKEN ]] || die "--cert-method dns requires --cf-token"
      log "issuing certificate via DNS-01 (Cloudflare)"
      apt-get install -y -qq python3-certbot-dns-cloudflare >>"$LOG_FILE" 2>&1 \
        || die "cannot install certbot dns-cloudflare plugin"
      umask 077
      printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > /etc/letsencrypt/cloudflare.ini
      if certbot certonly --dns-cloudflare \
           --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
           -d "$DOMAIN" --email "$EMAIL" --agree-tos --no-eff-email --non-interactive \
           >>"$LOG_FILE" 2>&1; then
        ok "certificate issued"
      else
        self_signed_cert
      fi ;;
    http)
      log "issuing certificate via HTTP-01"
      if certbot certonly --webroot -w "$WWW_ROOT/$DOMAIN" -d "$DOMAIN" \
           --email "$EMAIL" --agree-tos --no-eff-email --non-interactive \
           --deploy-hook "systemctl reload nginx" >>"$LOG_FILE" 2>&1; then
        ok "certificate issued"
      else
        warn "certbot failed — is the domain pointed at this server and is Cloudflare proxy off?"
        self_signed_cert
      fi ;;
  esac
}

setup_nginx_tls() {
  log "configuring nginx (127.0.0.1:8443)"
  backup_file "$NGINX_SITES/$DOMAIN.conf"
  cat > "$NGINX_SITES/$DOMAIN.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    root $WWW_ROOT/$DOMAIN;
    index index.html;

    location /.well-known/acme-challenge/ {
        root $WWW_ROOT/$DOMAIN;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:8443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate $CERT_CRT;
    ssl_certificate_key $CERT_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    root $WWW_ROOT/$DOMAIN;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  nginx -t >>"$LOG_FILE" 2>&1 || die "nginx config test failed"
  systemctl reload nginx
}

install_xray() {
  if command -v xray >/dev/null; then
    ok "xray already installed: $(xray version | awk 'NR==1')"
    return 0
  fi
  log "installing Xray-core"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install \
    >>"$LOG_FILE" 2>&1 || die "Xray installation failed (see $LOG_FILE)"
  command -v xray >/dev/null || die "xray binary not found after install"
  ok "$(xray version | awk 'NR==1')"
}

generate_credentials() {
  if [[ -z $UUID_VALUE ]]; then
    UUID_VALUE=$(xray uuid) || die "cannot generate UUID"
  fi
  if [[ -z $PRIVATE_KEY || -z $PUBLIC_KEY ]]; then
    local out
    out=$(xray x25519) || die "xray x25519 failed"
    PRIVATE_KEY=$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')
    PUBLIC_KEY=$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /(public|password)/ {print $2; exit}')
    [[ -n $PRIVATE_KEY && -n $PUBLIC_KEY ]] || die "cannot parse xray x25519 output"
  fi
  if [[ -z $SHORT_ID ]]; then
    SHORT_ID=$(openssl rand -hex 8)
  fi
}

download_wgcf() {
  local dir=$1 arch tag url
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) return 1 ;;
  esac
  tag=$(curl -fsSL --max-time 20 https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null || true)
  [[ -n $tag ]] || return 1
  url="https://github.com/ViRb3/wgcf/releases/download/${tag}/wgcf_${tag#v}_linux_${arch}"
  curl -fsSL --max-time 90 "$url" -o "$dir/wgcf" 2>/dev/null || return 1
  chmod +x "$dir/wgcf"
}

parse_warp() {
  local dir=$1 p a cid
  p="$dir/wgcf-profile.conf"
  a="$dir/wgcf-account.toml"
  [[ -f $p ]] || return 1
  WG_PRIV=$(awk -F' *= *' '/^PrivateKey/{print $2; exit}' "$p")
  WG_PUB=$(awk -F' *= *' '/^PublicKey/{print $2; exit}' "$p")
  WG_ENDPOINT=$(awk -F' *= *' '/^Endpoint/{print $2; exit}' "$p")
  WG_V4=$(awk -F' *= *' '/^Address/ && $2 ~ /\./ {print $2; exit}' "$p")
  WG_V6=$(awk -F' *= *' '/^Address/ && $2 ~ /:/ {print $2; exit}' "$p")
  [[ -n $WG_PRIV && -n $WG_PUB && -n $WG_ENDPOINT && -n $WG_V4 && -n $WG_V6 ]] || return 1
  # Xray expects bare addresses; wgcf writes them with /32 and /128
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

prepare_warp() {
  [[ $WARP == "all" ]] || { ok "WARP disabled"; return 0; }
  local dir="$STATE_DIR/warp"
  mkdir -p "$dir"

  if [[ -f "$dir/wgcf-profile.conf" && -f "$dir/wgcf-account.toml" && $FORCE -eq 0 ]]; then
    if parse_warp "$dir"; then ok "existing WARP profile loaded"; return 0; fi
  fi

  log "registering Cloudflare WARP"
  if ! download_wgcf "$dir"; then
    warn "cannot download wgcf; continuing without WARP"
    WARP="off"
    return 0
  fi
  if ! ( cd "$dir" && ./wgcf register --accept-tos >/dev/null 2>&1 && ./wgcf generate >/dev/null 2>&1 ); then
    warn "WARP registration failed (blocked network?); continuing without WARP"
    WARP="off"
    return 0
  fi
  if ! parse_warp "$dir"; then
    warn "cannot parse WARP profile; continuing without WARP"
    WARP="off"
    return 0
  fi
  ok "WARP profile ready ($WG_ENDPOINT)"
}

fix_xray_perms() {
  local user grp
  user=$(systemctl show -p User --value xray 2>/dev/null || true)
  [[ -n $user ]] || user="root"
  grp=$(systemctl show -p Group --value xray 2>/dev/null || true)
  [[ -n $grp ]] || grp=$(id -gn "$user" 2>/dev/null || echo root)

  chown root:"$grp" "$XRAY_DIR" "$XRAY_CONF" 2>/dev/null || true
  chmod 750 "$XRAY_DIR"
  chmod 640 "$XRAY_CONF"
}

write_xray_config() {
  log "writing Xray config"
  mkdir -p "$XRAY_DIR"

  local base rules default_rule wg client_json
  if [[ $TRANSPORT == "grpc" || $MUX -eq 1 ]]; then
    client_json=$(jq -n --arg uuid "$UUID_VALUE" '{id:$uuid, email:"user1"}')
  else
    client_json=$(jq -n --arg uuid "$UUID_VALUE" '{id:$uuid, flow:"xtls-rprx-vision", email:"user1"}')
  fi

  base=$(jq -n \
    --argjson client "$client_json" \
    --arg domain "$DOMAIN" \
    --arg priv "$PRIVATE_KEY" \
    --arg sid "$SHORT_ID" \
    --arg net "$TRANSPORT" \
    '{
      log: {loglevel: "warning"},
      inbounds: [{
        tag: "vless-reality",
        listen: "::",
        port: 443,
        protocol: "vless",
        settings: {
          clients: [$client],
          decryption: "none"
        },
        streamSettings: {
          network: $net,
          security: "reality",
          realitySettings: {
            target: "127.0.0.1:8443",
            xver: 0,
            serverNames: [$domain],
            privateKey: $priv,
            shortIds: [$sid]
          }
        },
        sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
      }],
      outbounds: [
        {tag: "direct", protocol: "freedom", settings: {domainStrategy: "UseIP"}},
        {tag: "block", protocol: "blackhole"}
      ],
      routing: {domainStrategy: "IPIfNonMatch", rules: []}
    }') || die "cannot build base config"

  if [[ $TRANSPORT == "grpc" ]]; then
    base=$(jq --arg svc "$GRPC_SERVICE" \
      '.inbounds[0].streamSettings.grpcSettings = {serviceName:$svc}' <<<"$base") \
      || die "cannot add gRPC settings"
  fi

  rules='[]'
  if [[ $BLOCK_RU -eq 1 ]]; then
    rules=$(jq -c '. + [
      {type:"field", domain:["regexp:^.*\\.ru$","regexp:^.*\\.xn--p1ai$","regexp:^.*\\.su$"], outboundTag:"block"},
      {type:"field", ip:["geoip:ru"], outboundTag:"block"}
    ]' <<<"$rules") || die "cannot build RU rules"
  fi
  rules=$(jq -c '. + [
    {type:"field", ip:["geoip:private"], outboundTag:"block"},
    {type:"field", protocol:["bittorrent"], outboundTag:"block"}
  ]' <<<"$rules") || die "cannot build block rules"

  if [[ $WARP == "all" ]]; then
    wg=$(jq -n \
      --arg k "$WG_PRIV" --arg p "$WG_PUB" --arg e "$WG_ENDPOINT" \
      --arg a4 "$WG_V4" --arg a6 "$WG_V6" --argjson r "$WG_RESERVED" \
      '{tag:"warp", protocol:"wireguard", settings:{
         secretKey:$k,
         address:[$a4,$a6],
         peers:[{publicKey:$p, endpoint:$e}],
         reserved:$r,
         noKernelTun:true,
         mtu:1280}}') || die "cannot build WARP outbound"
    base=$(jq --argjson wg "$wg" '.outbounds = [$wg] + .outbounds' <<<"$base") \
      || die "cannot add WARP outbound"
    base=$(jq '.routing.balancers = [{tag:"warp-balancer", selector:["warp"], fallbackTag:"direct", strategy:{type:"leastPing"}}]
               | .observatory = {subjectSelector:["warp"], probeUrl:"https://www.cloudflare.com/cdn-cgi/trace", probeInterval:"60s"}' \
      <<<"$base") || die "cannot add balancer"
    default_rule='{"type":"field","network":"tcp,udp","balancerTag":"warp-balancer"}'
  else
    default_rule='{"type":"field","network":"tcp,udp","outboundTag":"direct"}'
  fi

  rules=$(jq -c --argjson d "$default_rule" '. + [$d]' <<<"$rules") \
    || die "cannot add default rule"
  base=$(jq --argjson r "$rules" '.routing.rules = $r' <<<"$base") \
    || die "cannot attach routing rules"

  printf '%s\n' "$base" | jq . > "$XRAY_CONF" || die "cannot write $XRAY_CONF"
  fix_xray_perms
}

swap_target_to_dest() {
  if jq -e '.inbounds[0].streamSettings.realitySettings | has("target")' "$XRAY_CONF" >/dev/null 2>&1; then
    jq '.inbounds[0].streamSettings.realitySettings.dest = .inbounds[0].streamSettings.realitySettings.target
        | del(.inbounds[0].streamSettings.realitySettings.target)' \
      "$XRAY_CONF" > "$XRAY_CONF.tmp" && mv "$XRAY_CONF.tmp" "$XRAY_CONF"
    fix_xray_perms
  fi
}

start_xray() {
  log "starting Xray"
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray || true
  sleep 2

  if ! systemctl is-active --quiet xray; then
    warn "Xray did not start; retrying with legacy 'dest' key"
    swap_target_to_dest
    systemctl restart xray || true
    sleep 2
  fi
  if ! systemctl is-active --quiet xray; then
    journalctl -u xray -n 40 --no-pager >&2 || true
    die "Xray failed to start"
  fi

  if ! xray run -test -c "$XRAY_CONF" >/dev/null 2>&1; then
    warn "xray run -test reports an error (service is running)"
  fi
  ok "Xray is running"
}

decoy_ok() {
  local body
  body=$(curl -sk --max-time 15 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" 2>/dev/null) || return 1
  [[ $body == *"$DECOY_NAME"* ]]
}

verify_install() {
  log "verifying"
  port_listening 443 || die "443 is not listening"
  port_listening 80 || die "80 is not listening"
  port_listening 8443 || die "127.0.0.1:8443 is not listening"

  local ok_decoy=0
  if decoy_ok; then ok_decoy=1; fi

  if [[ $ok_decoy -eq 0 ]] \
     && jq -e '.inbounds[0].streamSettings.realitySettings | has("target")' "$XRAY_CONF" >/dev/null 2>&1; then
    warn "REALITY fallback check failed; retrying with legacy 'dest' key"
    swap_target_to_dest
    systemctl restart xray || true
    sleep 2
    if decoy_ok; then ok_decoy=1; fi
  fi

  if [[ $ok_decoy -eq 1 ]]; then
    ok "decoy is served through REALITY fallback"
  else
    warn "could not fetch the decoy through 443 (check certificate/nginx)"
  fi

  local hdr
  hdr=$(curl -sI --max-time 10 -H "Host: $DOMAIN" "http://127.0.0.1/" 2>/dev/null) || true
  if grep -q "301" <<<"$hdr"; then
    ok "http -> https redirect works"
  else
    warn "http redirect check failed"
  fi
}

save_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  jq -n \
    --arg domain "$DOMAIN" \
    --arg uuid "$UUID_VALUE" \
    --arg priv "$PRIVATE_KEY" \
    --arg pub "$PUBLIC_KEY" \
    --arg sid "$SHORT_ID" \
    --arg endpoint "$ENDPOINT" \
    --arg warp "$WARP" \
    --argjson block_ru "$BLOCK_RU" \
    --argjson mux "$MUX" \
    --arg transport "$TRANSPORT" \
    --arg grpc "$GRPC_SERVICE" \
    --arg cert "$CERT_CRT" \
    --arg installed "$(date -Is)" \
    '{domain:$domain, uuid:$uuid, private_key:$priv, public_key:$pub, short_id:$sid,
      endpoint:$endpoint, warp:$warp, block_ru:$block_ru, mux:$mux,
      transport:$transport, grpc_service:$grpc, cert:$cert, installed_at:$installed}' \
    > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

grpc_note() {
  [[ $TRANSPORT == "grpc" ]] || return 0
  cat <<EOF

gRPC transport: HTTP/2 multiplexes all streams over one TCP connection.
sing-box outbound example:

{
  "type": "vless",
  "server": "$ENDPOINT",
  "server_port": 443,
  "uuid": "$UUID_VALUE",
  "tls": {
    "enabled": true,
    "server_name": "$DOMAIN",
    "utls": {"enabled": true, "fingerprint": "firefox"},
    "reality": {"enabled": true, "public_key": "$PUBLIC_KEY", "short_id": "$SHORT_ID"}
  },
  "transport": {"type": "grpc", "service_name": "$GRPC_SERVICE"}
}
EOF
}

mux_note() {
  [[ $MUX -eq 1 ]] || return 0
  cat <<'EOF'

Mux mode: Vision is disabled on the server so the client may multiplex.
  Xray-based clients (v2rayN, v2rayNG, NekoBox with Xray core):
    enable Mux, concurrency 8-16, xudpConcurrency 16-32,
    xudpProxyUDP443 = reject.
  sing-box/Hiddify use smux and cannot talk to Xray Mux.Cool; they will
  still work without multiplexing, just with one TCP connection per stream.
EOF
}

print_links() {
  local lit dom
  lit=$(make_link "$ENDPOINT" "$UUID_VALUE")
  printf '\n%s--- client link (IPv6) ---%s\n%s\n' "$C_BLU" "$C_OFF" "$lit"
  if getent ahostsv6 "$DOMAIN" >/dev/null 2>&1; then
    dom=$(make_link "$DOMAIN" "$UUID_VALUE")
    printf '\n%s--- client link (domain, AAAA is live) ---%s\n%s\n' "$C_BLU" "$C_OFF" "$dom"
  fi
  if [[ $DO_QR -eq 1 ]] && command -v qrencode >/dev/null; then
    printf '\n'
    qrencode -t ANSIUTF8 "$lit" || true
  fi
  printf '\n'
  mux_note
  grpc_note
}

print_summary() {
  cat <<EOF

${C_GRN}Installation complete${C_OFF}

  domain (SNI) : $DOMAIN
  endpoint     : $ENDPOINT
  WARP         : $WARP
  block RU     : $BLOCK_RU
  transport    : $TRANSPORT${GRPC_SERVICE:+ ($GRPC_SERVICE)}
  mux          : $MUX
  certificate  : $CERT_CRT

  Config       : $XRAY_CONF
  State        : $STATE_FILE
  Log          : $LOG_FILE

  Add a user   : bash install.sh --add-user <name>
  Show links   : bash install.sh --links
  Status       : bash install.sh --status
  Uninstall    : bash install.sh --uninstall

  Check from the client:
    curl -6 https://$DOMAIN            # decoy page
    curl https://www.cloudflare.com/cdn-cgi/trace   # warp=on if WARP is up

EOF
  print_links
}

do_install() {
  require_root
  mkdir -p "$STATE_DIR" "$BACKUP_ROOT" "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"

  preflight_os
  ensure_packages
  load_state
  collect_params
  check_ports
  check_dns

  log "installing $APP_NAME $APP_VERSION"

  setup_sysctl
  setup_firewall
  setup_nginx_http
  issue_cert
  setup_nginx_tls
  install_xray
  generate_credentials
  prepare_warp
  write_xray_config
  start_xray
  verify_install
  save_state
  print_summary
}

# ---------------------------------------------------------------- subcommands --

require_state() {
  [[ -f $STATE_FILE ]] || die "no installation found ($STATE_FILE)"
  command -v jq >/dev/null || die "jq is required"
}

load_transport_state() {
  [[ -f $STATE_FILE ]] || return 0
  [[ $TRANSPORT_SET -eq 1 ]] && return 0
  local v
  v=$(jq -r '.transport // "tcp"' "$STATE_FILE" 2>/dev/null || true)
  if [[ $v == "grpc" ]]; then TRANSPORT="grpc"; fi
  v=$(jq -r '.grpc_service // empty' "$STATE_FILE" 2>/dev/null || true)
  if [[ -n $v && -z $GRPC_SERVICE ]]; then GRPC_SERVICE=$v; fi
  return 0
}

load_mux_state() {
  [[ -f $STATE_FILE ]] || return 0
  if [[ $TRANSPORT == "grpc" ]]; then MUX=0; return 0; fi
  [[ $MUX_SET -eq 1 ]] && return 0
  local v
  v=$(jq -r '.mux // false' "$STATE_FILE" 2>/dev/null || true)
  if [[ $v == "true" ]]; then MUX=1; fi
  return 0
}

do_add_user() {
  require_root
  require_state
  load_transport_state
  load_mux_state
  [[ -f $XRAY_CONF ]] || die "missing $XRAY_CONF"
  local name id backup link count flowval=""
  count=$(jq '.inbounds[0].settings.clients | length' "$XRAY_CONF")
  name=${ADD_USER_NAME:-user$((count + 1))}
  id=$(xray uuid)
  if [[ $TRANSPORT == "tcp" && $MUX -eq 0 ]]; then flowval="xtls-rprx-vision"; fi

  backup_file "$XRAY_CONF"
  backup="$XRAY_CONF.bak.$$"
  cp -a "$XRAY_CONF" "$backup"
  if ! jq --arg id "$id" --arg email "$name" --arg flow "$flowval" \
       '.inbounds[0].settings.clients += [({id:$id, email:$email} + (if $flow != "" then {flow:$flow} else {} end))]' \
       "$XRAY_CONF" > "$XRAY_CONF.tmp"; then
    rm -f "$XRAY_CONF.tmp"
    die "jq failed"
  fi
  mv "$XRAY_CONF.tmp" "$XRAY_CONF"
  fix_xray_perms
  if ! xray run -test -c "$XRAY_CONF" >/dev/null 2>&1; then
    mv "$backup" "$XRAY_CONF"
    die "config test failed, change reverted"
  fi
  rm -f "$backup"
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray || die "Xray failed to restart"

  DOMAIN=$(jq -r '.domain' "$STATE_FILE")
  PUBLIC_KEY=$(jq -r '.public_key' "$STATE_FILE")
  SHORT_ID=$(jq -r '.short_id' "$STATE_FILE")
  ENDPOINT=$(jq -r '.endpoint' "$STATE_FILE")
  link=$(make_link "$ENDPOINT" "$id")
  printf '\nUser %s added.\n%s\n\n' "$name" "$link"
}

do_links() {
  require_state
  [[ -f $XRAY_CONF ]] || die "missing $XRAY_CONF"
  load_transport_state
  load_mux_state
  DOMAIN=$(jq -r '.domain' "$STATE_FILE")
  PUBLIC_KEY=$(jq -r '.public_key' "$STATE_FILE")
  SHORT_ID=$(jq -r '.short_id' "$STATE_FILE")
  ENDPOINT=$(jq -r '.endpoint' "$STATE_FILE")
  UUID_VALUE=$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$XRAY_CONF")

  local name id domain_live=0
  if getent ahostsv6 "$DOMAIN" >/dev/null 2>&1; then domain_live=1; fi

  while IFS=$'\t' read -r name id; do
    [[ -n $id ]] || continue
    printf '%s--- %s ---%s\n' "$C_BLU" "${name:-user}" "$C_OFF"
    make_link "$ENDPOINT" "$id"
    if [[ $domain_live -eq 1 ]]; then
      make_link "$DOMAIN" "$id"
    fi
    printf '\n'
  done < <(jq -r '.inbounds[0].settings.clients[] | [(.email // "user"), .id] | @tsv' "$XRAY_CONF")
  mux_note
  grpc_note
}

do_enable_mux() {
  require_root
  require_state
  load_transport_state
  load_mux_state
  [[ -f $XRAY_CONF ]] || die "missing $XRAY_CONF"
  if [[ $TRANSPORT == "grpc" ]]; then
    die "gRPC already multiplexes; mux is only for tcp (switch with --transport tcp)"
  fi
  if [[ $MUX -eq 1 ]]; then
    ok "mux mode is already enabled"
    do_links
    return 0
  fi

  local backup="$XRAY_CONF.bak.$$"
  cp -a "$XRAY_CONF" "$backup"
  if ! jq 'del(.inbounds[0].settings.clients[].flow)' "$XRAY_CONF" > "$XRAY_CONF.tmp"; then
    rm -f "$XRAY_CONF.tmp" "$backup"
    die "jq failed"
  fi
  mv "$XRAY_CONF.tmp" "$XRAY_CONF"
  fix_xray_perms

  if ! xray run -test -c "$XRAY_CONF" >/dev/null 2>&1; then
    mv "$backup" "$XRAY_CONF"
    fix_xray_perms
    die "config test failed; change reverted"
  fi

  systemctl restart xray || true
  sleep 2
  if ! systemctl is-active --quiet xray; then
    mv "$backup" "$XRAY_CONF"
    fix_xray_perms
    systemctl restart xray || true
    die "Xray failed to restart; change reverted"
  fi
  rm -f "$backup"

  jq '.mux = true' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  MUX=1
  MUX_SET=1
  ok "mux mode enabled (Vision disabled); issue new links"
  do_links
}

do_disable_mux() {
  require_root
  require_state
  load_mux_state
  [[ -f $XRAY_CONF ]] || die "missing $XRAY_CONF"
  if [[ $MUX -eq 0 ]]; then
    ok "mux mode is already disabled"
    do_links
    return 0
  fi

  local backup="$XRAY_CONF.bak.$$"
  cp -a "$XRAY_CONF" "$backup"
  if ! jq '.inbounds[0].settings.clients[].flow = "xtls-rprx-vision"' "$XRAY_CONF" > "$XRAY_CONF.tmp"; then
    rm -f "$XRAY_CONF.tmp" "$backup"
    die "jq failed"
  fi
  mv "$XRAY_CONF.tmp" "$XRAY_CONF"
  fix_xray_perms

  if ! xray run -test -c "$XRAY_CONF" >/dev/null 2>&1; then
    mv "$backup" "$XRAY_CONF"
    fix_xray_perms
    die "config test failed; change reverted"
  fi

  systemctl restart xray || true
  sleep 2
  if ! systemctl is-active --quiet xray; then
    mv "$backup" "$XRAY_CONF"
    fix_xray_perms
    systemctl restart xray || true
    die "Xray failed to restart; change reverted"
  fi
  rm -f "$backup"

  jq '.mux = false' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  MUX=0
  MUX_SET=1
  ok "mux mode disabled (Vision restored); issue new links"
  do_links
}

do_status() {
  require_state
  DOMAIN=$(jq -r '.domain' "$STATE_FILE")
  local cert
  cert=$(jq -r '.cert' "$STATE_FILE")

  echo "--- state ---"
  jq 'del(.private_key)' "$STATE_FILE"
  echo "--- services ---"
  systemctl is-active xray nginx 2>/dev/null || true
  echo "--- listeners ---"
  ss -lntp 2>/dev/null | grep -E ':(80|443|8443)\b' || true
  echo "--- certificate ---"
  if [[ -f $cert ]]; then
    openssl x509 -in "$cert" -noout -subject -issuer -enddate 2>/dev/null || true
  else
    echo "not found: $cert"
  fi
  echo "--- xray test ---"
  xray run -test -c "$XRAY_CONF" && echo ok || echo failed
}

do_uninstall() {
  require_root
  local domain=""
  if [[ -f $STATE_FILE ]]; then
    domain=$(jq -r '.domain // empty' "$STATE_FILE" 2>/dev/null || true)
  fi
  [[ -n $domain ]] || domain=$DOMAIN

  if [[ $FORCE -eq 0 ]]; then
    if have_tty; then
      read -rp "Remove Xray, nginx site '${domain:-?}' and installer state? [y/N] " ans < /dev/tty \
        || die "aborted"
      [[ ${ans:-} == y* ]] || { echo "aborted"; exit 1; }
    else
      die "pass --force to uninstall non-interactively"
    fi
  fi

  log "stopping services"
  systemctl disable --now xray >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/xray.service /usr/local/bin/xray
  rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  systemctl daemon-reload || true

  if [[ -n $domain ]]; then
    rm -f "$NGINX_ENABLED/$domain.conf" "$NGINX_SITES/$domain.conf"
    rm -rf "${WWW_ROOT:?}/$domain"
    if nginx -t >/dev/null 2>&1; then systemctl reload nginx || true; fi
  fi

  rm -rf "$STATE_DIR"
  ok "removed (certificates in /etc/letsencrypt were kept)"
}

# --------------------------------------------------------------------- main --

case "$ACTION" in
  install)   do_install ;;
  add-user)  do_add_user ;;
  links)     do_links ;;
  status)    do_status ;;
  uninstall) do_uninstall ;;
  enable-mux)  do_enable_mux ;;
  disable-mux) do_disable_mux ;;
  *)         die "unknown action: $ACTION" ;;
esac
