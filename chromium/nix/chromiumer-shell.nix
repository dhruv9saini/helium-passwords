# This environment follows Chromium 150.0.7871.181's NixOS shell pin.
# Upstream source:
#   tools/nix/make-shell-for-system.nix at
#   24b04c927b23c39cf9c5227cc8dc6f64a744c8e9
# Chromium pins nixpkgs a793ee3962cf3be3d0e9ed1022147ea9cd34eea9
# with the hash below. Keep all three values together when Chromium advances.
{ system ? builtins.currentSystem }:

let
  nixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/a793ee3962cf3be3d0e9ed1022147ea9cd34eea9.tar.gz";
    sha256 = "023d699q0s9rzx87x6fp4jpar7pd2y3h4gjrdmhznxbbg76yhp9b";
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
  name = "helium-chromium-150-env";

  targetPkgs = packages: with packages; [
    # Helium/depot_tools bootstrap and source preparation.
    bash
    bison
    cacert
    coreutils
    curl
    file
    findutils
    flex
    gawk
    git
    gnugrep
    gnumake
    gnused
    gnutar
    gzip
    heliumPython
    jq
    imagemagick
    ninja
    nodejs_22
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
    yasm
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
  runScript = pkgs.writeShellScript "helium-chromium-150-run" ''
    if [ -n "''${HELIUM_NIX_RUN_COMMAND:+set}" ]; then
      eval "$HELIUM_NIX_RUN_COMMAND"
    else
      exec bash
    fi
  '';
})
