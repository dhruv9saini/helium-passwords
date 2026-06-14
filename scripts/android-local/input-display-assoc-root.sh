#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}
JAR="$ROOT/input-display-assoc.jar"
CLASS=net.dhruv.inputdisplayassoc.InputDisplayAssoc

run_assoc() {
  /system/bin/app_process -Djava.class.path="$JAR" /system/bin "$CLASS" "$@"
}

external_display_line() {
  cmd display get-displays 2>/dev/null |
    sed -n '/^Display id [0-9][0-9]*: DisplayInfo/ { /type EXTERNAL/ p }' |
    head -n 1
}

display_id_from_line() {
  sed -n 's/^Display id \([0-9][0-9]*\):.*/\1/p'
}

display_unique_from_line() {
  sed -n 's/.*uniqueId "\([^"]*\)".*/\1/p'
}

display_port_from_line() {
  sed -n 's/.*address {port=\([0-9][0-9]*\),.*/\1/p'
}

external_input_rows() {
  dumpsys input 2>/dev/null |
    awk '
      function emit() {
        if (name != "" && external && wanted) {
          if (location != "") {
            print "port\t" location "\t" name
          }
          if (descriptor != "") {
            print "descriptor\t" descriptor "\t" name
          }
        }
      }
      /^    -?[0-9]+: / {
        emit()
        name = $0
        sub(/^    -?[0-9]+: /, "", name)
        location = ""
        descriptor = ""
        external = 0
        wanted = 0
        if (name ~ /Magic Keyboard|Arch Magic Keyboard Remap/) {
          external = 1
          wanted = 1
        }
        next
      }
      /^    [A-Za-z]/ {
        emit()
        name = ""
        next
      }
      name != "" && /Classes:/ {
        if ($0 ~ /EXTERNAL/) external = 1
        if ($0 ~ /CURSOR|KEYBOARD|ALPHAKEY/) wanted = 1
      }
      name != "" && /Descriptor:/ {
        descriptor = $2
      }
      name != "" && /Location:/ {
        location = $2
      }
      END {
        emit()
      }
    ' |
    grep -Ev 'uinput_nav|Virtual|touchpanel|gpio-keys|pmic_|oplus|sun-mtp' |
    sort -u
}

associate() {
  line=$(external_display_line)
  [ -n "$line" ] || {
    echo "no external display; skipping input association"
    exit 0
  }

  display_unique=$(printf '%s\n' "$line" | display_unique_from_line)
  display_port=$(printf '%s\n' "$line" | display_port_from_line)
  display_id=$(printf '%s\n' "$line" | display_id_from_line)
  [ -n "$display_unique" ] || {
    echo "external display has no unique id; skipping input association"
    exit 0
  }

  echo "associating external inputs to display $display_id $display_unique port ${display_port:-unknown}"
  external_input_rows |
    while IFS="$(printf '\t')" read -r kind value name; do
      [ -n "$value" ] || continue
      case "$kind" in
        port)
          if [ -n "${display_port:-}" ]; then
            run_assoc add-port "$value" "$display_unique" "$display_port" || true
          else
            run_assoc add-port "$value" "$display_unique" || true
          fi
          ;;
        descriptor)
          run_assoc add-descriptor "$value" "$display_unique" || true
          ;;
      esac
      echo "$kind $value $name"
    done
}

clear() {
  external_input_rows |
    while IFS="$(printf '\t')" read -r kind value name; do
      [ -n "$value" ] || continue
      case "$kind" in
        port)
          run_assoc remove-port "$value" || true
          ;;
        descriptor)
          run_assoc remove-descriptor "$value" || true
          ;;
      esac
      echo "cleared $kind $value $name"
    done
}

case "${1:-apply}" in
  apply)
    associate
    ;;
  clear|reset|remove)
    clear
    ;;
  list)
    run_assoc list
    ;;
  *)
    echo "usage: $0 [apply|clear|list]" >&2
    exit 2
    ;;
esac
