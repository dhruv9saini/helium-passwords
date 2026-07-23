#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
# shellcheck source=../android-media/protocol-fixture.conf
source "$repo_root/scripts/android-media/protocol-fixture.conf"
caddy_bin=${CADDY_BIN:-$HOME/.local/share/helium-media-fixtures/bin/caddy}
provenance=$HOME/.local/state/helium-media-fixtures/provenance.env
[[ -x "$caddy_bin" && -f "$provenance" && ! -L "$provenance" ]] || {
  echo "install the pinned protocol fixture source before running the runtime test" >&2
  exit 1
}
[[ "$($caddy_bin version | awk '{print $1}')" == "v$CADDY_VERSION" ]]
grep -Fqx "caddy_version=$CADDY_VERSION" "$provenance"
grep -Fqx "caddy_archive_sha256=$CADDY_LINUX_AMD64_TAR_SHA256" "$provenance"
for command in curl jq node openssl ss tailscale; do
  command -v "$command" >/dev/null
done
curl --version | head -1
curl --version | grep -qw HTTP2
curl --version | grep -qw HTTP3

status=$(tailscale status --json)
fixture_host=$(jq -er '.Self.DNSName | rtrimstr(".")' <<<"$status")
fixture_ip=$(jq -er '[.Self.TailscaleIPs[] | select(test("^[0-9]+\\."))][0]' <<<"$status")
[[ "$fixture_host" == *.ts.net && "$fixture_ip" == 100.* ]]

find_test_ports() {
  local base=$((46000 + (BASHPID % 1000) * 3))
  local attempt backend h2 h3
  for attempt in {1..100}; do
    backend=$base
    h2=$((base + 1))
    h3=$((base + 2))
    if ! ss -ltnH "( sport = :$backend or sport = :$h2 or sport = :$h3 )" | grep -q . &&
       ! ss -lunH "( sport = :$h2 or sport = :$h3 )" | grep -q .; then
      FIXTURE_BACKEND_PORT=$backend
      FIXTURE_H2_PORT=$h2
      FIXTURE_H3_PORT=$h3
      return
    fi
    base=$((base + 3))
  done
  echo 'no isolated protocol-fixture test port range is free' >&2
  exit 1
}
find_test_ports

proof_dir=$(mktemp -d /tmp/helium-media-source-proof.XXXXXX)
backend_pid=
caddy_pid=
cleanup() {
  [[ -z "$caddy_pid" ]] || kill "$caddy_pid" 2>/dev/null || true
  [[ -z "$backend_pid" ]] || kill "$backend_pid" 2>/dev/null || true
  [[ -z "$caddy_pid" ]] || wait "$caddy_pid" 2>/dev/null || true
  [[ -z "$backend_pid" ]] || wait "$backend_pid" 2>/dev/null || true
  case "$proof_dir" in
    /tmp/helium-media-source-proof.*) find "$proof_dir" -depth -delete ;;
  esac
}
trap cleanup EXIT

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -subj "/CN=$fixture_host" \
  -addext "subjectAltName=DNS:$fixture_host,IP:$fixture_ip" \
  -days 1 -keyout "$proof_dir/key.pem" -out "$proof_dir/cert.pem" \
  >/dev/null 2>&1
chmod 0600 "$proof_dir/key.pem" "$proof_dir/cert.pem"
spki=$(openssl x509 -in "$proof_dir/cert.pem" -pubkey -noout |
  openssl pkey -pubin -outform DER 2>/dev/null |
  openssl dgst -sha256 -binary | openssl base64 -A)
cert_sha=$(openssl x509 -in "$proof_dir/cert.pem" -outform DER | sha256sum | awk '{print $1}')
printf '{"schema_version":1,"disposable_only":true,"tls_mode":"private-ca-spki","hostname":"%s","h2_port":%s,"h3_port":%s,"leaf_spki_sha256_base64":"%s","leaf_cert_sha256":"%s","required_chromium_switch":"--ignore-certificate-errors-spki-list=%s"}\n' \
  "$fixture_host" "$FIXTURE_H2_PORT" "$FIXTURE_H3_PORT" "$spki" \
  "$cert_sha" "$spki" >"$proof_dir/fixture-provenance.json"

node "$repo_root/scripts/android-media/fixture-server.mjs" \
  --host 127.0.0.1 --port "$FIXTURE_BACKEND_PORT" \
  >"$proof_dir/backend.log" 2>&1 &
backend_pid=$!
for attempt in {1..100}; do
  if curl --fail --silent --max-time 1 --noproxy '*' --output /dev/null \
    "http://127.0.0.1:$FIXTURE_BACKEND_PORT/manifest.json" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
curl --fail --silent --max-time 1 --noproxy '*' --output /dev/null \
  "http://127.0.0.1:$FIXTURE_BACKEND_PORT/manifest.json"

export HELIUM_MEDIA_TLS_HOST=$fixture_host
export HELIUM_MEDIA_TLS_IP=$fixture_ip
export HELIUM_MEDIA_BACKEND_PORT=$FIXTURE_BACKEND_PORT
export HELIUM_MEDIA_H2_PORT=$FIXTURE_H2_PORT
export HELIUM_MEDIA_H3_PORT=$FIXTURE_H3_PORT
export HELIUM_MEDIA_TLS_CERT=$proof_dir/cert.pem
export HELIUM_MEDIA_TLS_KEY=$proof_dir/key.pem
export HELIUM_MEDIA_ASSET_ROOT=$proof_dir
export HELIUM_MEDIA_RECEIPT_ROOT=$proof_dir
export XDG_DATA_HOME=$proof_dir/caddy-data
export XDG_CONFIG_HOME=$proof_dir/caddy-config
"$caddy_bin" validate \
  --config "$repo_root/scripts/android-media/Caddyfile.protocol-fixtures" \
  --adapter caddyfile >/dev/null
"$caddy_bin" run \
  --config "$repo_root/scripts/android-media/Caddyfile.protocol-fixtures" \
  --adapter caddyfile >"$proof_dir/caddy.log" 2>&1 &
caddy_pid=$!
for attempt in {1..100}; do
  if ss -ltnH "( sport = :$FIXTURE_H2_PORT )" | grep -q . &&
     ss -lunH "( sport = :$FIXTURE_H3_PORT )" | grep -q .; then
    break
  fi
  sleep 0.1
done

request() {
  local protocol=$1 port=$2 name=$3
  curl --fail --silent --show-error --max-time 10 --noproxy '*' \
    "$protocol" --tlsv1.3 --tls-max 1.3 --cacert "$proof_dir/cert.pem" \
    --resolve "$fixture_host:$port:$fixture_ip" \
    --dump-header "$proof_dir/$name.headers" \
    --output "$proof_dir/$name.body" --write-out '%{http_version}' \
    "https://$fixture_host:$port/stream/fetch?encoding=identity"
}

h2_version=$(request --http2 "$FIXTURE_H2_PORT" h2)
h3_warm_version=$(request --http2 "$FIXTURE_H3_PORT" h3-warm)
h3_version=$(request --http3-only "$FIXTURE_H3_PORT" h3)
[[ "$h2_version" == 2 && "$h3_warm_version" == 2 && "$h3_version" == 3 ]]
if request --http3-only "$FIXTURE_H2_PORT" h2-direct-h3 >/dev/null 2>&1; then
  echo "HTTP/2-only fixture unexpectedly accepted direct HTTP/3" >&2
  exit 1
fi
! ss -lunH "( sport = :$FIXTURE_H2_PORT )" | grep -q .
! grep -qi '^alt-svc:' "$proof_dir/h2.headers"
[[ $(tr -d '\r' <"$proof_dir/h3-warm.headers" |
  grep -Fxc "alt-svc: h3=\":$FIXTURE_H3_PORT\"; ma=86400") == 1 ]]
[[ $(grep -Eic '^alt-svc:' "$proof_dir/h3-warm.headers") == 1 ]]
for headers in "$proof_dir"/*.headers; do
  ! grep -Eqi '^(server|set-cookie):' "$headers"
done
printf 'chunk-01\nchunk-02\nchunk-03\nchunk-04\n' >"$proof_dir/expected"
for body in "$proof_dir/h2.body" "$proof_dir/h3-warm.body" "$proof_dir/h3.body"; do
  cmp "$proof_dir/expected" "$body"
done
curl --fail --silent --show-error --max-time 10 --noproxy '*' \
  --http2 --tlsv1.3 --tls-max 1.3 --cacert "$proof_dir/cert.pem" \
  --resolve "$fixture_host:$FIXTURE_H2_PORT:$fixture_ip" \
  --output "$proof_dir/served-receipt.json" \
  "https://$fixture_host:$FIXTURE_H2_PORT/fixture-provenance.json"
cmp "$proof_dir/fixture-provenance.json" "$proof_dir/served-receipt.json"

printf 'android_protocol_fixture_runtime=passed h2=%s h3_warm=%s h3=%s\n' \
  "$h2_version" "$h3_warm_version" "$h3_version"
