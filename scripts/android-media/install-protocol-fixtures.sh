#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
# shellcheck source=protocol-fixture.conf
source "$repo_root/scripts/android-media/protocol-fixture.conf"
action=${1:-}

[[ "$CADDY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ &&
   "$CADDY_LINUX_AMD64_TAR_SHA256" =~ ^[0-9a-f]{64}$ ]]
for port in "$FIXTURE_BACKEND_PORT" "$FIXTURE_H2_PORT" "$FIXTURE_H3_PORT"; do
  [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1024 && "$port" -le 65535 ]]
done

user_id=$(id -u)
user_name=$(id -un)
user_home=$(getent passwd "$user_id" | cut -d: -f6)
[[ -n "$user_home" && "$user_home" == /* ]] || {
  echo "cannot resolve the current user's absolute home" >&2
  exit 1
}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$user_id}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}

share_root=$user_home/.local/share/helium-media-fixtures
state_root=$user_home/.local/state/helium-media-fixtures
unit_root=$user_home/.config/systemd/user
binary=$share_root/bin/caddy
node_binary=$share_root/bin/node
caddyfile=$share_root/config/Caddyfile
assets_root=$share_root/assets
runtime_root=$share_root/runtime
tls_root=$state_root/tls
endpoint_env=$state_root/config/endpoint.env
receipt=$state_root/config/fixture-provenance.json
marker=$state_root/SYNTHETIC_ONLY
backend_service=helium-media-fixture-backend.service
protocol_service=helium-media-fixture-protocol.service
caddy_url=https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz

case "$action" in
  install-source|issue-private-tls|enable|disable)
    exec 8>"$XDG_RUNTIME_DIR/helium-media-fixtures.operator.lock"
    chmod 0600 "$XDG_RUNTIME_DIR/helium-media-fixtures.operator.lock"
    flock -n 8 || {
      echo "another Helium media fixture operator action is running" >&2
      exit 1
    }
    ;;
esac

verify_user_manager() {
  [[ -S "$XDG_RUNTIME_DIR/bus" ]] || {
    echo "the user systemd bus is unavailable: $XDG_RUNTIME_DIR/bus" >&2
    return 1
  }
  systemctl --user is-system-running >/dev/null
  [[ "$(loginctl show-user "$user_name" -p Linger --value)" == yes ]] || {
    echo "user lingering must be enabled for durable fixture supervision" >&2
    return 1
  }
}

require_marker() {
  [[ -f "$marker" && ! -L "$marker" &&
      "$(cat "$marker")" == credential-free-protocol-fixtures-v1 ]] || {
    echo "credential-free synthetic fixture marker is missing or invalid" >&2
    return 1
  }
}

tailscale_identity() {
  local status
  status=$(tailscale status --json)
  jq -e '
    .BackendState == "Running" and .Self.Online == true and
    (.Self.DNSName | type == "string" and endswith(".ts.net.")) and
    ([.Self.TailscaleIPs[] | select(test("^[0-9]+\\."))] | length == 1)
  ' <<<"$status" >/dev/null || {
    echo "lm must have one online Tailscale IPv4 identity and a .ts.net name" >&2
    return 1
  }
  tls_hostname=$(jq -er '.Self.DNSName | rtrimstr(".")' <<<"$status")
  tls_ip=$(jq -er '[.Self.TailscaleIPs[] | select(test("^[0-9]+\\."))][0]' <<<"$status")
}

read_endpoint_config() {
  [[ -f "$endpoint_env" && ! -L "$endpoint_env" ]] || {
    echo "fixture endpoint configuration is missing: $endpoint_env" >&2
    return 1
  }
  mapfile -t lines <"$endpoint_env"
  [[ ${#lines[@]} -eq 12 ]] || {
    echo "fixture endpoint configuration must contain exactly twelve lines" >&2
    return 1
  }
  HELIUM_MEDIA_TLS_HOST=${lines[0]#HELIUM_MEDIA_TLS_HOST=}
  HELIUM_MEDIA_TLS_IP=${lines[1]#HELIUM_MEDIA_TLS_IP=}
  HELIUM_MEDIA_BACKEND_PORT=${lines[2]#HELIUM_MEDIA_BACKEND_PORT=}
  HELIUM_MEDIA_H2_PORT=${lines[3]#HELIUM_MEDIA_H2_PORT=}
  HELIUM_MEDIA_H3_PORT=${lines[4]#HELIUM_MEDIA_H3_PORT=}
  HELIUM_MEDIA_TLS_CERT=${lines[5]#HELIUM_MEDIA_TLS_CERT=}
  HELIUM_MEDIA_TLS_KEY=${lines[6]#HELIUM_MEDIA_TLS_KEY=}
  HELIUM_MEDIA_TLS_CA_CERT=${lines[7]#HELIUM_MEDIA_TLS_CA_CERT=}
  HELIUM_MEDIA_TLS_SPKI=${lines[8]#HELIUM_MEDIA_TLS_SPKI=}
  HELIUM_MEDIA_TLS_CERT_SHA256=${lines[9]#HELIUM_MEDIA_TLS_CERT_SHA256=}
  HELIUM_MEDIA_ASSET_ROOT=${lines[10]#HELIUM_MEDIA_ASSET_ROOT=}
  HELIUM_MEDIA_RECEIPT_ROOT=${lines[11]#HELIUM_MEDIA_RECEIPT_ROOT=}
  [[ "${lines[0]}" == "HELIUM_MEDIA_TLS_HOST=$HELIUM_MEDIA_TLS_HOST" &&
      "${lines[1]}" == "HELIUM_MEDIA_TLS_IP=$HELIUM_MEDIA_TLS_IP" &&
      "${lines[2]}" == "HELIUM_MEDIA_BACKEND_PORT=$HELIUM_MEDIA_BACKEND_PORT" &&
      "${lines[3]}" == "HELIUM_MEDIA_H2_PORT=$HELIUM_MEDIA_H2_PORT" &&
      "${lines[4]}" == "HELIUM_MEDIA_H3_PORT=$HELIUM_MEDIA_H3_PORT" &&
      "${lines[5]}" == "HELIUM_MEDIA_TLS_CERT=$HELIUM_MEDIA_TLS_CERT" &&
      "${lines[6]}" == "HELIUM_MEDIA_TLS_KEY=$HELIUM_MEDIA_TLS_KEY" &&
      "${lines[7]}" == "HELIUM_MEDIA_TLS_CA_CERT=$HELIUM_MEDIA_TLS_CA_CERT" &&
      "${lines[8]}" == "HELIUM_MEDIA_TLS_SPKI=$HELIUM_MEDIA_TLS_SPKI" &&
      "${lines[9]}" == "HELIUM_MEDIA_TLS_CERT_SHA256=$HELIUM_MEDIA_TLS_CERT_SHA256" &&
      "${lines[10]}" == "HELIUM_MEDIA_ASSET_ROOT=$HELIUM_MEDIA_ASSET_ROOT" &&
      "${lines[11]}" == "HELIUM_MEDIA_RECEIPT_ROOT=$HELIUM_MEDIA_RECEIPT_ROOT" ]] || {
    echo "fixture endpoint configuration keys or order are invalid" >&2
    return 1
  }
}

verify_source() {
  require_marker
  [[ -x "$binary" && ! -L "$binary" ]] || {
    echo "pinned Caddy binary is missing" >&2
    return 1
  }
  [[ "$($binary version | awk '{print $1}')" == "v$CADDY_VERSION" ]] || {
    echo "installed Caddy version does not match the repository pin" >&2
    return 1
  }
  [[ -x "$node_binary" && ! -L "$node_binary" &&
      "$($node_binary --version)" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "installed Node runtime is missing or invalid" >&2
    return 1
  }
  cmp "$repo_root/scripts/android-media/Caddyfile.protocol-fixtures" "$caddyfile"
  cmp "$repo_root/scripts/android-media/fixture-server.mjs" \
    "$runtime_root/fixture-server.mjs"
  cmp "$repo_root/scripts/android-media/wait-fixture-backend.sh" \
    "$runtime_root/wait-fixture-backend.sh"
  [[ -L "$assets_root/current" &&
      "$(readlink "$assets_root/current")" =~ ^generations/[0-9a-f]{64}$ ]] || {
    echo "immutable fixture asset generation is missing" >&2
    return 1
  }
  (cd "$assets_root/current" && sha256sum -c SHA256SUMS >/dev/null)
}

verify_tls() {
  tailscale_identity
  read_endpoint_config
  [[ "$HELIUM_MEDIA_TLS_HOST" == "$tls_hostname" &&
      "$HELIUM_MEDIA_TLS_IP" == "$tls_ip" &&
      "$HELIUM_MEDIA_BACKEND_PORT" == "$FIXTURE_BACKEND_PORT" &&
      "$HELIUM_MEDIA_H2_PORT" == "$FIXTURE_H2_PORT" &&
      "$HELIUM_MEDIA_H3_PORT" == "$FIXTURE_H3_PORT" &&
      "$HELIUM_MEDIA_TLS_CERT" == "$tls_root/current/cert.pem" &&
      "$HELIUM_MEDIA_TLS_KEY" == "$tls_root/current/key.pem" &&
      "$HELIUM_MEDIA_TLS_CA_CERT" == "$tls_root/current/ca-cert.pem" &&
      "$HELIUM_MEDIA_ASSET_ROOT" == "$assets_root/current" &&
      "$HELIUM_MEDIA_RECEIPT_ROOT" == "$state_root/config" &&
      "$HELIUM_MEDIA_TLS_SPKI" =~ ^[A-Za-z0-9+/]{43}=$ &&
      "$HELIUM_MEDIA_TLS_CERT_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "fixture endpoint does not match lm's live tailnet identity or pinned ports" >&2
    return 1
  }
  [[ -L "$tls_root/current" &&
      "$(readlink "$tls_root/current")" =~ ^generations/[0-9a-f]{64}$ ]] || {
    echo "immutable fixture TLS generation is missing" >&2
    return 1
  }
  for file in "$HELIUM_MEDIA_TLS_CERT" "$HELIUM_MEDIA_TLS_KEY" \
    "$HELIUM_MEDIA_TLS_CA_CERT" "$tls_root/current/ca-key.pem"; do
    [[ -f "$file" && ! -L "$file" && "$(stat -c %a "$file")" == 600 ]] || {
      echo "fixture TLS material must be regular and mode 0600: $file" >&2
      return 1
    }
  done
  openssl x509 -in "$HELIUM_MEDIA_TLS_CERT" -noout -checkhost "$tls_hostname" >/dev/null
  openssl x509 -in "$HELIUM_MEDIA_TLS_CERT" -noout -checkend 86400 >/dev/null
  openssl verify -CAfile "$HELIUM_MEDIA_TLS_CA_CERT" -purpose sslserver \
    -verify_hostname "$tls_hostname" "$HELIUM_MEDIA_TLS_CERT" >/dev/null
  cert_public=$(openssl x509 -in "$HELIUM_MEDIA_TLS_CERT" -pubkey -noout | sha256sum | awk '{print $1}')
  key_public=$(openssl pkey -in "$HELIUM_MEDIA_TLS_KEY" -pubout 2>/dev/null | sha256sum | awk '{print $1}')
  [[ "$cert_public" == "$key_public" ]] || {
    echo "fixture TLS certificate and private key do not match" >&2
    return 1
  }
  ca_cert_public=$(openssl x509 -in "$HELIUM_MEDIA_TLS_CA_CERT" -pubkey -noout | sha256sum | awk '{print $1}')
  ca_key_public=$(openssl pkey -in "$tls_root/current/ca-key.pem" -pubout 2>/dev/null | sha256sum | awk '{print $1}')
  [[ "$ca_cert_public" == "$ca_key_public" ]] || {
    echo "fixture CA certificate and private key do not match" >&2
    return 1
  }
  spki=$(openssl x509 -in "$HELIUM_MEDIA_TLS_CERT" -pubkey -noout |
    openssl pkey -pubin -outform DER 2>/dev/null |
    openssl dgst -sha256 -binary | openssl base64 -A)
  cert_sha=$(openssl x509 -in "$HELIUM_MEDIA_TLS_CERT" -outform DER | sha256sum | awk '{print $1}')
  [[ "$HELIUM_MEDIA_TLS_SPKI" == "$spki" &&
      "$HELIUM_MEDIA_TLS_CERT_SHA256" == "$cert_sha" ]] || {
    echo "fixture TLS SPKI or certificate fingerprint is stale" >&2
    return 1
  }
  [[ -f "$receipt" && ! -L "$receipt" && "$(stat -c %a "$receipt")" == 600 ]]
  jq -e --arg host "$tls_hostname" --argjson h2 "$FIXTURE_H2_PORT" \
    --argjson h3 "$FIXTURE_H3_PORT" --arg spki "$spki" --arg cert "$cert_sha" '
      .schema_version == 1 and .disposable_only == true and
      .tls_mode == "private-ca-spki" and .hostname == $host and
      .h2_port == $h2 and .h3_port == $h3 and
      .leaf_spki_sha256_base64 == $spki and .leaf_cert_sha256 == $cert and
      .required_chromium_switch == ("--ignore-certificate-errors-spki-list=" + $spki)
    ' "$receipt" >/dev/null
  export HELIUM_MEDIA_TLS_HOST HELIUM_MEDIA_TLS_IP HELIUM_MEDIA_BACKEND_PORT
  export HELIUM_MEDIA_H2_PORT HELIUM_MEDIA_H3_PORT HELIUM_MEDIA_TLS_CERT
  export HELIUM_MEDIA_TLS_KEY HELIUM_MEDIA_TLS_CA_CERT HELIUM_MEDIA_TLS_SPKI
  export HELIUM_MEDIA_TLS_CERT_SHA256 HELIUM_MEDIA_ASSET_ROOT
  export HELIUM_MEDIA_RECEIPT_ROOT
  "$binary" validate --config "$caddyfile" --adapter caddyfile >/dev/null
}

port_is_free() {
  local protocol=$1 port=$2
  case "$protocol" in
    tcp) ! ss -ltnH "( sport = :$port )" | grep -q . ;;
    udp) ! ss -lunH "( sport = :$port )" | grep -q . ;;
    *) return 2 ;;
  esac
}

wait_live() {
  local attempt
  for attempt in {1..100}; do
    if verify_live >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  verify_live
}

verify_live() {
  verify_source
  verify_tls
  local temp h2_version h3_warm_version h3_version
  temp=$(mktemp -d /tmp/helium-media-protocol-verify.XXXXXX)
  cleanup_verify() {
    case "$temp" in
      /tmp/helium-media-protocol-verify.*) find "$temp" -depth -delete ;;
    esac
  }
  trap cleanup_verify RETURN
  h2_version=$(curl --fail --silent --show-error --max-time 10 \
    --noproxy '*' --http2 --tlsv1.3 --tls-max 1.3 \
    --cacert "$HELIUM_MEDIA_TLS_CA_CERT" \
    --resolve "$HELIUM_MEDIA_TLS_HOST:$HELIUM_MEDIA_H2_PORT:$HELIUM_MEDIA_TLS_IP" \
    --dump-header "$temp/h2.headers" --output "$temp/h2.body" \
    --write-out '%{http_version}' \
    "https://$HELIUM_MEDIA_TLS_HOST:$HELIUM_MEDIA_H2_PORT/stream/fetch?encoding=identity")
  [[ "$h2_version" == 2 ]]
  ! grep -qi '^alt-svc:' "$temp/h2.headers"
  ! grep -qi '^set-cookie:' "$temp/h2.headers"
  if curl --fail --silent --show-error --connect-timeout 1 --max-time 2 \
    --noproxy '*' --http3-only --tlsv1.3 --tls-max 1.3 \
    --cacert "$HELIUM_MEDIA_TLS_CA_CERT" \
    --resolve "$HELIUM_MEDIA_TLS_HOST:$HELIUM_MEDIA_H2_PORT:$HELIUM_MEDIA_TLS_IP" \
    --output /dev/null \
    "https://$HELIUM_MEDIA_TLS_HOST:$HELIUM_MEDIA_H2_PORT/stream/fetch?encoding=identity" \
    2>/dev/null; then
    echo "HTTP/2-only fixture unexpectedly accepted direct HTTP/3" >&2
    return 1
  fi

  h3_warm_version=$(curl --fail --silent --show-error --max-time 10 \
    --noproxy '*' --http2 --tlsv1.3 --tls-max 1.3 \
    --cacert "$HELIUM_MEDIA_TLS_CA_CERT" \
    --resolve "$HELIUM_MEDIA_TLS_HOST:$HELIUM_MEDIA_H3_PORT:$HELIUM_MEDIA_TLS_IP" \
    --dump-header "$temp/h3-warm.headers" --output "$temp/h3-warm.body" \
    --write-out '%{http_version}' \
    "https://$HELIUM_MEDIA_TLS_HOST:$HELIUM_MEDIA_H3_PORT/stream/fetch?encoding=identity")
  [[ "$h3_warm_version" == 2 ]]
  grep -Eqi "^alt-svc:.*h3=\":$HELIUM_MEDIA_H3_PORT\"" "$temp/h3-warm.headers"
  ! grep -qi '^set-cookie:' "$temp/h3-warm.headers"

  h3_version=$(curl --fail --silent --show-error --max-time 10 \
    --noproxy '*' --http3-only --tlsv1.3 --tls-max 1.3 \
    --cacert "$HELIUM_MEDIA_TLS_CA_CERT" \
    --resolve "$HELIUM_MEDIA_TLS_HOST:$HELIUM_MEDIA_H3_PORT:$HELIUM_MEDIA_TLS_IP" \
    --dump-header "$temp/h3.headers" --output "$temp/h3.body" \
    --write-out '%{http_version}' \
    "https://$HELIUM_MEDIA_TLS_HOST:$HELIUM_MEDIA_H3_PORT/stream/fetch?encoding=identity")
  [[ "$h3_version" == 3 ]]
  ! grep -qi '^set-cookie:' "$temp/h3.headers"
  printf 'chunk-01\nchunk-02\nchunk-03\nchunk-04\n' >"$temp/expected"
  for body in "$temp/h2.body" "$temp/h3-warm.body" "$temp/h3.body"; do
    cmp "$temp/expected" "$body"
  done
  curl --fail --silent --show-error --max-time 10 --noproxy '*' \
    --http2 --tlsv1.3 --tls-max 1.3 --cacert "$HELIUM_MEDIA_TLS_CA_CERT" \
    --resolve "$HELIUM_MEDIA_TLS_HOST:$HELIUM_MEDIA_H2_PORT:$HELIUM_MEDIA_TLS_IP" \
    --output "$temp/receipt.json" \
    "https://$HELIUM_MEDIA_TLS_HOST:$HELIUM_MEDIA_H2_PORT/fixture-provenance.json"
  cmp "$receipt" "$temp/receipt.json"
  trap - RETURN
  cleanup_verify
  printf 'h2_url=https://%s:%s/stream/fetch?encoding=identity\n' \
    "$HELIUM_MEDIA_TLS_HOST" "$HELIUM_MEDIA_H2_PORT"
  printf 'h3_url=https://%s:%s/stream/fetch?encoding=identity\n' \
    "$HELIUM_MEDIA_TLS_HOST" "$HELIUM_MEDIA_H3_PORT"
  printf 'fixture_spki_sha256_base64=%s\n' "$HELIUM_MEDIA_TLS_SPKI"
  echo "protocol_fixtures=live"
}

case "$action" in
  install-source)
    verify_user_manager
    if systemctl --user is-active --quiet "$backend_service" ||
       systemctl --user is-active --quiet "$protocol_service"; then
      echo "refusing fixture source install while a fixture service is active" >&2
      exit 1
    fi
    temp=$(mktemp -d /tmp/helium-media-fixture-install.XXXXXX)
    cleanup_install() { find "$temp" -depth -delete; }
    trap cleanup_install EXIT
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.3 \
      --output "$temp/caddy.tar.gz" "$caddy_url"
    echo "$CADDY_LINUX_AMD64_TAR_SHA256  $temp/caddy.tar.gz" | sha256sum -c -
    [[ "$(tar -tzf "$temp/caddy.tar.gz" | sort | tr '\n' ' ')" == \
      "LICENSE README.md caddy " ]] || {
      echo "Caddy archive inventory changed" >&2
      exit 1
    }
    tar -xzf "$temp/caddy.tar.gz" -C "$temp" caddy
    [[ "$($temp/caddy version | awk '{print $1}')" == "v$CADDY_VERSION" ]]
    node_source=$(command -v node)
    node_source=$(readlink -f "$node_source")
    [[ -x "$node_source" && "$($node_source --version)" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
    install -d -m0700 "$share_root/bin" "$share_root/config" "$runtime_root" \
      "$assets_root/generations" "$state_root/config" "$tls_root/generations" \
      "$unit_root"
    if [[ -e "$marker" ]]; then
      require_marker
    else
      printf 'credential-free-protocol-fixtures-v1\n' >"$state_root/.SYNTHETIC_ONLY.incoming"
      chmod 0600 "$state_root/.SYNTHETIC_ONLY.incoming"
      mv "$state_root/.SYNTHETIC_ONLY.incoming" "$marker"
    fi
    assets_incoming=$(mktemp -d "$assets_root/generations/.incoming.XXXXXX")
    "$repo_root/scripts/android-media/generate-fixtures.sh" "$assets_incoming"
    asset_generation=$(sha256sum "$assets_incoming/SHA256SUMS" | awk '{print $1}')
    assets_final=$assets_root/generations/$asset_generation
    if [[ -e "$assets_final" ]]; then
      (cd "$assets_final" && sha256sum -c SHA256SUMS >/dev/null)
      find "$assets_incoming" -depth -delete
    else
      chmod -R u=rwX,go= "$assets_incoming"
      mv "$assets_incoming" "$assets_final"
    fi
    current_incoming=$assets_root/.current.$$
    ln -s "generations/$asset_generation" "$current_incoming"
    mv -Tf "$current_incoming" "$assets_root/current"
    install -m0755 "$temp/caddy" "$binary.incoming"
    mv -T "$binary.incoming" "$binary"
    install -m0755 "$node_source" "$node_binary.incoming"
    mv -T "$node_binary.incoming" "$node_binary"
    install -m0644 "$repo_root/scripts/android-media/Caddyfile.protocol-fixtures" \
      "$caddyfile.incoming"
    mv -T "$caddyfile.incoming" "$caddyfile"
    install -m0644 "$repo_root/scripts/android-media/fixture-server.mjs" \
      "$runtime_root/fixture-server.mjs.incoming"
    mv -T "$runtime_root/fixture-server.mjs.incoming" "$runtime_root/fixture-server.mjs"
    install -m0755 "$repo_root/scripts/android-media/wait-fixture-backend.sh" \
      "$runtime_root/wait-fixture-backend.sh.incoming"
    mv -T "$runtime_root/wait-fixture-backend.sh.incoming" \
      "$runtime_root/wait-fixture-backend.sh"
    install -m0644 "$repo_root/systemd/helium-media-fixture-backend.service" \
      "$unit_root/$backend_service"
    install -m0644 "$repo_root/systemd/helium-media-fixture-protocol.service" \
      "$unit_root/$protocol_service"
    fixture_source_sha=$(sha256sum "$repo_root/scripts/android-media/fixture-server.mjs" | awk '{print $1}')
    node_sha=$(sha256sum "$node_binary" | awk '{print $1}')
    node_version=$($node_binary --version)
    provenance=$state_root/provenance.env
    {
      printf 'schema_version=1\n'
      printf 'caddy_version=%s\n' "$CADDY_VERSION"
      printf 'caddy_archive_sha256=%s\n' "$CADDY_LINUX_AMD64_TAR_SHA256"
      printf 'fixture_server_sha256=%s\n' "$fixture_source_sha"
      printf 'node_version=%s\n' "$node_version"
      printf 'node_sha256=%s\n' "$node_sha"
      printf 'asset_generation=%s\n' "$asset_generation"
    } >"$provenance.incoming"
    chmod 0600 "$provenance.incoming"
    mv -T "$provenance.incoming" "$provenance"
    systemctl --user daemon-reload
    verify_source
    cleanup_install
    trap - EXIT
    echo "protocol_fixture_source=installed_inactive"
    ;;
  issue-private-tls)
    verify_user_manager
    verify_source
    if systemctl --user is-active --quiet "$backend_service" ||
       systemctl --user is-active --quiet "$protocol_service"; then
      echo "refusing fixture TLS issuance while a fixture service is active" >&2
      exit 1
    fi
    tailscale_identity
    incoming=$(mktemp -d "$tls_root/generations/.incoming.XXXXXX")
    endpoint_temp=$(mktemp "$state_root/config/.endpoint.XXXXXX")
    receipt_temp=$(mktemp "$state_root/config/.receipt.XXXXXX")
    cleanup_tls() {
      [[ ! -e "$endpoint_temp" ]] || find "$endpoint_temp" -delete
      [[ ! -e "$receipt_temp" ]] || find "$receipt_temp" -delete
      [[ -z "${incoming:-}" || ! -e "$incoming" ]] || find "$incoming" -depth -delete
    }
    trap cleanup_tls EXIT
    openssl ecparam -name prime256v1 -genkey -noout -out "$incoming/ca-key.pem"
    openssl req -new -x509 -sha256 -days 30 -key "$incoming/ca-key.pem" \
      -subj '/CN=Helium disposable media fixture CA' \
      -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
      -addext 'keyUsage=critical,keyCertSign,cRLSign' \
      -out "$incoming/ca-cert.pem"
    openssl ecparam -name prime256v1 -genkey -noout -out "$incoming/key.pem"
    openssl req -new -sha256 -key "$incoming/key.pem" -subj "/CN=$tls_hostname" \
      -addext "subjectAltName=DNS:$tls_hostname,IP:$tls_ip" \
      -addext 'basicConstraints=critical,CA:FALSE' \
      -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
      -addext 'extendedKeyUsage=serverAuth' -out "$incoming/leaf.csr"
    openssl x509 -req -sha256 -days 30 -in "$incoming/leaf.csr" \
      -copy_extensions copy -CA "$incoming/ca-cert.pem" \
      -CAkey "$incoming/ca-key.pem" -CAcreateserial -out "$incoming/cert.pem" \
      >/dev/null 2>&1
    find "$incoming" -maxdepth 1 -type f \
      \( -name 'leaf.csr' -o -name '*.srl' \) -delete
    chmod 0600 "$incoming/ca-cert.pem" "$incoming/ca-key.pem" \
      "$incoming/cert.pem" "$incoming/key.pem"
    openssl x509 -in "$incoming/cert.pem" -noout -checkhost "$tls_hostname" >/dev/null
    openssl x509 -in "$incoming/cert.pem" -noout -checkend 86400 >/dev/null
    openssl verify -CAfile "$incoming/ca-cert.pem" -purpose sslserver \
      -verify_hostname "$tls_hostname" "$incoming/cert.pem" >/dev/null
    spki=$(openssl x509 -in "$incoming/cert.pem" -pubkey -noout |
      openssl pkey -pubin -outform DER 2>/dev/null |
      openssl dgst -sha256 -binary | openssl base64 -A)
    cert_sha=$(openssl x509 -in "$incoming/cert.pem" -outform DER | sha256sum | awk '{print $1}')
    generation=$(sha256sum "$incoming/cert.pem" | awk '{print $1}')
    final_generation=$tls_root/generations/$generation
    if [[ -e "$final_generation" ]]; then
      cmp "$incoming/ca-cert.pem" "$final_generation/ca-cert.pem"
      cmp "$incoming/ca-key.pem" "$final_generation/ca-key.pem"
      cmp "$incoming/cert.pem" "$final_generation/cert.pem"
      cmp "$incoming/key.pem" "$final_generation/key.pem"
      find "$incoming" -depth -delete
    else
      mv "$incoming" "$final_generation"
    fi
    incoming=
    current_incoming=$tls_root/.current.$$
    ln -s "generations/$generation" "$current_incoming"
    mv -Tf "$current_incoming" "$tls_root/current"
    printf '{"schema_version":1,"disposable_only":true,"tls_mode":"private-ca-spki","hostname":"%s","h2_port":%s,"h3_port":%s,"leaf_spki_sha256_base64":"%s","leaf_cert_sha256":"%s","required_chromium_switch":"--ignore-certificate-errors-spki-list=%s"}\n' \
      "$tls_hostname" "$FIXTURE_H2_PORT" "$FIXTURE_H3_PORT" "$spki" \
      "$cert_sha" "$spki" >"$receipt_temp"
    chmod 0600 "$receipt_temp"
    mv -T "$receipt_temp" "$receipt"
    printf 'HELIUM_MEDIA_TLS_HOST=%s\nHELIUM_MEDIA_TLS_IP=%s\nHELIUM_MEDIA_BACKEND_PORT=%s\nHELIUM_MEDIA_H2_PORT=%s\nHELIUM_MEDIA_H3_PORT=%s\nHELIUM_MEDIA_TLS_CERT=%s\nHELIUM_MEDIA_TLS_KEY=%s\nHELIUM_MEDIA_TLS_CA_CERT=%s\nHELIUM_MEDIA_TLS_SPKI=%s\nHELIUM_MEDIA_TLS_CERT_SHA256=%s\nHELIUM_MEDIA_ASSET_ROOT=%s\nHELIUM_MEDIA_RECEIPT_ROOT=%s\n' \
      "$tls_hostname" "$tls_ip" "$FIXTURE_BACKEND_PORT" "$FIXTURE_H2_PORT" \
      "$FIXTURE_H3_PORT" "$tls_root/current/cert.pem" "$tls_root/current/key.pem" \
      "$tls_root/current/ca-cert.pem" "$spki" "$cert_sha" "$assets_root/current" \
      "$state_root/config" >"$endpoint_temp"
    chmod 0600 "$endpoint_temp"
    mv -T "$endpoint_temp" "$endpoint_env"
    sync "$tls_root" "$state_root/config"
    trap - EXIT
    verify_tls
    echo "protocol_fixture_private_tls=issued_inactive"
    printf 'fixture_spki_sha256_base64=%s\n' "$spki"
    ;;
  verify-source)
    verify_source
    echo "protocol_fixture_source=verified"
    ;;
  verify-endpoint)
    verify_source
    verify_tls
    echo "protocol_fixture_endpoint=verified"
    ;;
  verify-live)
    verify_live
    ;;
  enable)
    verify_user_manager
    verify_source
    verify_tls
    systemctl --user is-active --quiet "$protocol_service" && {
      echo "protocol fixture service is already active" >&2
      exit 1
    }
    for port in "$FIXTURE_BACKEND_PORT" "$FIXTURE_H2_PORT" "$FIXTURE_H3_PORT"; do
      port_is_free tcp "$port" || { echo "TCP port $port already has a listener" >&2; exit 1; }
    done
    for port in "$FIXTURE_H2_PORT" "$FIXTURE_H3_PORT"; do
      port_is_free udp "$port" || {
        echo "UDP port $port already has a listener" >&2
        exit 1
      }
    done
    if ! systemctl --user enable --now "$protocol_service"; then
      systemctl --user disable --now "$protocol_service" "$backend_service"
      echo "protocol fixture service failed to start and was disabled" >&2
      exit 1
    fi
    if ! wait_live; then
      systemctl --user disable --now "$protocol_service" "$backend_service"
      echo "protocol fixture service failed its HTTP/2/HTTP/3 health gate" >&2
      exit 1
    fi
    echo "protocol_fixture_service=enabled"
    ;;
  disable)
    systemctl --user disable --now "$protocol_service" "$backend_service"
    echo "protocol_fixture_service=disabled"
    echo "state_preserved=$state_root"
    ;;
  status)
    systemctl --user --no-pager --full status "$protocol_service" "$backend_service"
    verify_live
    ;;
  *)
    echo "usage: $0 <install-source|issue-private-tls|verify-source|verify-endpoint|verify-live|enable|disable|status>" >&2
    exit 64
    ;;
esac
