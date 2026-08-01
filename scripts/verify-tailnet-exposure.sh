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

jq -e --argjson port "$sync_port" '
  def configs:
    ., (.Foreground[]? | configs), (.Services[]? | configs);
  def object_or_error($label):
    if . == null then {}
    elif type == "object" then .
    else error($label + " must be an object")
    end;
  def numeric_port($label):
    if type == "string" and test("^[0-9]+$") then
      tonumber as $number |
      if $number >= 0 and $number <= 65535 and $number == ($number | floor)
      then $number
      else error($label + " is outside the TCP port range")
      end
    else error($label + " is not a numeric TCP port")
    end;
  def listener_port($label):
    if type != "string" then error($label + " is not a string")
    elif test("^.+:[0-9]+$") then
      capture(":(?<port>[0-9]+)$").port | numeric_port($label)
    else error($label + " has no explicit numeric port")
    end;
  def target_port($label):
    if type != "string" then error($label + " is not a string")
    elif test("^(?:[A-Za-z][A-Za-z0-9+.-]*://)?(?:\\[[^]]+\\]|[^/:?#]+):[0-9]+(?:[/?#].*)?$") then
      capture("^(?:[A-Za-z][A-Za-z0-9+.-]*://)?(?:\\[[^]]+\\]|[^/:?#]+):(?<port>[0-9]+)(?:[/?#].*)?$").port |
      numeric_port($label)
    else error($label + " has no explicit numeric endpoint port")
    end;
  [configs |
    ((.AllowFunnel | object_or_error("AllowFunnel")) | length == 0) and
    ((.TCP | object_or_error("TCP")) as $tcp |
      ([$tcp | keys[] | numeric_port("TCP listener") != $port] | all) and
      ([$tcp[] |
        if type == "object" then . else error("TCP listener must be an object") end |
        .TCPForward? | select(. != null) |
        target_port("TCPForward target") != $port
      ] | all)) and
    ((.Web | object_or_error("Web")) as $web |
      ([$web | keys[] | listener_port("Web listener") != $port] | all) and
      ([$web[] |
        if type == "object" then . else error("Web listener must be an object") end |
        (.Handlers | object_or_error("Web handlers"))[] |
        if type == "object" then . else error("Web handler must be an object") end |
        .Proxy? | select(. != null) |
        target_port("Web proxy target") != $port
      ] | all))
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
