#!/system/bin/sh

sleep "${HELIUM_PHONE_UI_BOOT_DELAY:-20}"
/data/local/chroots/arch/android-ui-preferences-root.sh >/dev/null 2>&1 || true
/data/local/chroots/arch/android-connected-display-auto-enable-root.sh start >/dev/null 2>&1 || true
