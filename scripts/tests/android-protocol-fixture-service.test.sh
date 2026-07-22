#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
installer=$repo_root/scripts/android-media/install-protocol-fixtures.sh
config=$repo_root/scripts/android-media/protocol-fixture.conf
caddyfile=$repo_root/scripts/android-media/Caddyfile.protocol-fixtures
backend=$repo_root/systemd/helium-media-fixture-backend.service
gateway=$repo_root/systemd/helium-media-fixture-protocol.service
readiness=$repo_root/scripts/android-media/wait-fixture-backend.sh

# shellcheck source=../android-media/protocol-fixture.conf
source "$config"
[[ "$CADDY_VERSION" == 2.11.3 ]]
[[ "$CADDY_LINUX_AMD64_TAR_SHA256" == \
  3894577b14657feab3624d782f64175050211e52a228a6f57b4f24f4b0d970f3 ]]
[[ "$FIXTURE_BACKEND_PORT" == 44722 ]]
[[ "$FIXTURE_H2_PORT" == 44723 ]]
[[ "$FIXTURE_H3_PORT" == 44724 ]]

grep -Fqx $'\tservers {$HELIUM_MEDIA_TLS_IP}:{$HELIUM_MEDIA_H2_PORT} {' "$caddyfile"
grep -Fqx $'\t\tprotocols h2' "$caddyfile"
grep -Fqx $'\tservers {$HELIUM_MEDIA_TLS_IP}:{$HELIUM_MEDIA_H3_PORT} {' "$caddyfile"
grep -Fqx $'\t\tprotocols h2 h3' "$caddyfile"
[[ $(grep -Fxc $'\tbind {$HELIUM_MEDIA_TLS_IP}' "$caddyfile") == 2 ]]
[[ $(grep -Fxc $'\t\tprotocols tls1.3' "$caddyfile") == 2 ]]
[[ $(grep -Fxc $'\t\treverse_proxy 127.0.0.1:{$HELIUM_MEDIA_BACKEND_PORT} {' "$caddyfile") == 2 ]]
[[ $(grep -Fxc $'\thandle /fixture-provenance.json {' "$caddyfile") == 2 ]]
[[ $(grep -Fxc $'\t\troot * {$HELIUM_MEDIA_RECEIPT_ROOT}' "$caddyfile") == 2 ]]
grep -Fq 'Alt-Svc "h3=\":{$HELIUM_MEDIA_H3_PORT}\"; ma=86400"' "$caddyfile"
grep -Fqx $'\tadmin off' "$caddyfile"
grep -Fqx $'\tauto_https off' "$caddyfile"
if grep -Eqi '(^|[[:space:]])(log|basicauth|basic_auth|forward_auth|cookie)([[:space:]]|$)' "$caddyfile"; then
  echo "protocol fixture Caddyfile gained logging, authentication, or cookie state" >&2
  exit 1
fi

for directive in \
  'NoNewPrivileges=yes' \
  'PrivateTmp=yes' \
  'PrivateDevices=yes' \
  'ProtectSystem=strict' \
  'ProtectHome=tmpfs' \
  'ProtectProc=invisible' \
  'RestrictNamespaces=yes' \
  'MemoryDenyWriteExecute=yes' \
  'RestrictAddressFamilies=AF_UNIX AF_INET' \
  'IPAddressDeny=any' \
  'IPAddressAllow=localhost' \
  'CapabilityBoundingSet=' \
  'AmbientCapabilities=' \
  'MemorySwapMax=0' \
  'UMask=0077'; do
  grep -Fqx "$directive" "$backend"
  grep -Fqx "$directive" "$gateway"
done
grep -Fqx 'IPAddressAllow=100.64.0.0/10' "$gateway"
grep -Fqx 'BindReadOnlyPaths=%h/.local/share/helium-media-fixtures/runtime' "$gateway"
grep -Fqx 'BindReadOnlyPaths=%h/.local/state/helium-media-fixtures/tls/current/cert.pem' "$gateway"
grep -Fqx 'BindReadOnlyPaths=%h/.local/state/helium-media-fixtures/tls/current/key.pem' "$gateway"
if grep -Fqx 'BindReadOnlyPaths=%h/.local/state/helium-media-fixtures/tls' "$gateway"; then
  echo "protocol service unexpectedly exposes the fixture CA private key directory" >&2
  exit 1
fi
grep -Fqx 'MemoryMax=128M' "$backend"
grep -Fqx 'MemoryMax=256M' "$gateway"
grep -Fqx 'TasksMax=32' "$backend"
grep -Fqx 'TasksMax=64' "$gateway"
grep -Fqx 'Requires=helium-media-fixture-backend.service' "$gateway"
grep -Fqx 'Type=simple' "$gateway"
grep -Fqx 'PartOf=helium-media-fixture-protocol.service' "$backend"
grep -Fqx 'ExecStartPre=%h/.local/share/helium-media-fixtures/runtime/wait-fixture-backend.sh' "$gateway"
grep -Fqx 'ExecStart=%h/.local/share/helium-media-fixtures/bin/node --jitless %h/.local/share/helium-media-fixtures/runtime/fixture-server.mjs --host 127.0.0.1 --port ${HELIUM_MEDIA_BACKEND_PORT} --media-dir ${HELIUM_MEDIA_ASSET_ROOT}' "$backend"

grep -Fq 'http://127.0.0.1:$HELIUM_MEDIA_BACKEND_PORT/manifest.json' "$readiness"
grep -Fq -- "--noproxy '*'" "$readiness"

grep -Fq "CADDY_LINUX_AMD64_TAR_SHA256" "$installer"
grep -Fq 'install -m0755 "$node_source" "$node_binary.incoming"' "$installer"
grep -Fq "issue-private-tls" "$installer"
grep -Fq "Helium disposable media fixture CA" "$installer"
grep -Fq "basicConstraints=critical,CA:TRUE,pathlen:0" "$installer"
grep -Fq 'chmod 0600 "$incoming/ca-cert.pem" "$incoming/ca-key.pem"' "$installer"
grep -Fq 'required_chromium_switch' "$installer"
grep -Fq -- "--noproxy '*' --http2 --tlsv1.3 --tls-max 1.3" "$installer"
grep -Fq -- "--noproxy '*' --http3-only --tlsv1.3 --tls-max 1.3" "$installer"
grep -Fq -- '--cacert "$HELIUM_MEDIA_TLS_CA_CERT"' "$installer"
grep -Fq 'grep -Eqi "^alt-svc:.*h3=' "$installer"
grep -Fq 'for port in "$FIXTURE_H2_PORT" "$FIXTURE_H3_PORT"' "$installer"
grep -Fq 'HTTP/2-only fixture unexpectedly accepted direct HTTP/3' "$installer"
grep -Fq 'systemctl --user disable --now "$protocol_service" "$backend_service"' "$installer"
if grep -Fq 'sudo ' "$installer"; then
  echo "rootless protocol fixture operator unexpectedly uses sudo" >&2
  exit 1
fi

echo "android_protocol_fixture_service=passed"
