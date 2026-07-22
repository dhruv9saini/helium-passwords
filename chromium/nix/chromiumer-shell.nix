# This environment follows Chromium 148.0.7778.178's NixOS shell pin.
# Upstream source:
#   tools/nix/make-shell-for-system.nix at
#   d096af1c9e98c45c3596e59620622b1a049bfecb
# Chromium pins nixpkgs bd85f316bebe290b96b35ddb5c0be62d1f0c9137
# with the hash below. Keep all three values together when Chromium advances.
{ system ? builtins.currentSystem }:

let
  nixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/bd85f316bebe290b96b35ddb5c0be62d1f0c9137.tar.gz";
    sha256 = "1qxr70li1biw260rccm6hjvmn1ysgq2h60pmpq1ww9h6fdv4y884";
  };
  pkgs = import nixpkgs { inherit system; };
  heliumPython = pkgs.python3.withPackages (pythonPackages: with pythonPackages; [
    httplib2
    pillow
    requests
    six
  ]);
in
(pkgs.buildFHSEnv {
  name = "helium-chromium-148-env";

  targetPkgs = packages: with packages; [
    # Helium/depot_tools bootstrap and source preparation.
    bash
    cacert
    coreutils
    curl
    file
    findutils
    gawk
    git
    gnugrep
    gnumake
    gnused
    gnutar
    gzip
    heliumPython
    jq
    openssh
    patch
    perl
    pkg-config
    quilt
    rsync
    unzip
    util-linux
    which
    xz
    zip
    zstd

    # Shared libraries from Chromium's matching official NixOS shell.
    alsa-lib
    at-spi2-atk
    cairo
    cups
    dbus
    expat
    glib
    gperf
    libdrm
    libxkbcommon
    mesa
    nspr
    nss
    pango
    systemd
    xorg.libX11
    xorg.libXcomposite
    xorg.libXdamage
    xorg.libXext
    xorg.libXfixes
    xorg.libXrandr
    xorg.libXtst
    xorg.libxcb
    xorg.xdpyinfo
    zlib
  ];

  # The checked wrapper supplies one shell-escaped command through this
  # variable. Return the FHS derivation itself: its `.env` attribute is only
  # for interactive nix-shell sessions and cannot be realized by nix-build.
  runScript = pkgs.writeShellScript "helium-chromium-148-run" ''
    if [ -n "''${HELIUM_NIX_RUN_COMMAND:+set}" ]; then
      eval "$HELIUM_NIX_RUN_COMMAND"
    else
      exec bash
    fi
  '';
})
