#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [TAILSCALE_SERVE_JSON]" >&2
  exit 64
fi

sync_port=44719
if [[ $# -eq 1 ]]; then
  serve_file=$(realpath -e "$1")
  [[ -f "$serve_file" && ! -L "$serve_file" ]] || {
    echo "Tailscale Serve configuration input is missing or unsafe" >&2
    exit 1
  }
  serve_config=$(<"$serve_file")
else
  serve_config=$(tailscale serve status --json)
fi

jq -e --arg port "$sync_port" '
  def configs:
    ., (.Foreground[]? | configs), (.Services[]? | configs);
  def targets_sync_port:
    test(":" + $port + "($|[/\\?#])");
  [configs |
    ((.AllowFunnel // {}) | length == 0) and
    (((.TCP // {}) | has($port)) | not) and
    ([((.Web // {}) | keys[]?) | endswith(":" + $port)] | any | not) and
    ([((.TCP // {})[]?.TCPForward?) | select(. != null) |
      if type == "string" then (targets_sync_port | not) else false end
    ] | all) and
    ([((.Web // {})[]?.Handlers[]?.Proxy?) | select(. != null) |
      if type == "string" then (targets_sync_port | not) else false end
    ] | all)
  ] | all
' <<<"$serve_config" >/dev/null || {
  echo "Helium Sync must have no Funnel, Serve listener, Web proxy, or TCP forward involving port 44719" >&2
  exit 1
}

canonical=$(jq -S -c . <<<"$serve_config")
printf 'serve_config_sha256=%s\n' \
  "$(printf '%s\n' "$canonical" | sha256sum | cut -d' ' -f1)"
printf 'sync_port=%s\n' "$sync_port"
printf 'tailnet_exposure=verified\n'
