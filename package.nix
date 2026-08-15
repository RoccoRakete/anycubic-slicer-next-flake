{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  unzip,
  buildFHSEnv,
  symlinkJoin,
  version,
  dateStamp,
  ubuntuStamp,
  srcHash,
}:
let
  anycubic-slicer-next-unwrapped = stdenv.mkDerivation {
    pname = "anycubic-slicer-next-unwrapped";
    inherit version;

    src = fetchurl {
      url = "https://cdn-universe-slicer.anycubic.com/prod/dists/noble/main/binary-amd64/develop_AnycubicSlicerNext-${version}_${dateStamp}-${ubuntuStamp}.deb";
      hash = srcHash;
    };

    nativeBuildInputs = [
      dpkg
      unzip
    ];

    sourceRoot = ".";
    unpackPhase = ''
      runHook preUnpack
      dpkg-deb -x $src .
      runHook postUnpack
    '';

    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin $out/lib $out/share
      cp -r usr/bin/AnycubicSlicerNext $out/bin/
      cp -r usr/lib/. $out/lib/
      cp -r usr/share/AnycubicSlicerNext $out/share/AnycubicSlicerNext

      install -Dm644 usr/share/applications/AnycubicSlicer.desktop \
        $out/share/applications/anycubic-slicer-next.desktop
      substituteInPlace $out/share/applications/anycubic-slicer-next.desktop \
        --replace-fail 'Exec=AnycubicSlicerNext %U' 'Exec=anycubic-slicer-next %U' \
        --replace-fail 'Icon=/usr/share/AnycubicSlicerNext/resources/images/AnycubicSlicer.png' 'Icon=anycubic-slicer-next'

      install -Dm644 usr/share/AnycubicSlicerNext/resources/images/AnycubicSlicer.png \
        $out/share/icons/hicolor/512x512/apps/anycubic-slicer-next.png
      install -Dm644 usr/share/AnycubicSlicerNext/resources/images/AnycubicSlicer.svg \
        $out/share/icons/hicolor/scalable/apps/anycubic-slicer-next.svg

      # libWorkbench.so's registerHandler() is a no-op stub in this build, so the
      # "pages://" URI scheme it's meant to serve never responds and the Workbench
      # tab stays blank. The real content (a Vue SPA) is embedded right there in the
      # .so as "<name>\0...<md5>\0...<zip data>": extract the zip and point the app
      # at it directly via the ACNEXT_WORKBENCH_ENV_VAR debug override instead.
      workbench_zip_offset=$(grep -abo $'PK\x03\x04' usr/lib/libWorkbench.so | head -1 | cut -d: -f1)
      mkdir -p "$out/share/AnycubicSlicerNext/resources/workbench"
      tail -c +$((workbench_zip_offset + 1)) usr/lib/libWorkbench.so > workbench.zip
      unzip -q workbench.zip -d "$out/share/AnycubicSlicerNext/resources/workbench"
      rm workbench.zip

      runHook postInstall
    '';

    meta = {
      description = "Anycubic Slicer Next (unwrapped, upstream .deb payload)";
      homepage = "https://github.com/ANYCUBIC-3D/AnycubicSlicer";
      license = lib.licenses.unfree;
      platforms = [ "x86_64-linux" ];
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };

  anycubic-slicer-next-fhs = buildFHSEnv {
    name = "anycubic-slicer-next";

    targetPkgs =
      pkgs:
      [ anycubic-slicer-next-unwrapped ]
      ++ (with pkgs; [
        webkitgtk_4_1
        libsoup_3
        gtk3
        glib
        glib-networking
        dbus
        mesa
        libGL
        libglvnd
        wayland
        libx11
        fontconfig
        cairo
        pango
        gdk-pixbuf
        expat
        zlib
        stdenv.cc.cc.lib
        gst_all_1.gstreamer
        gst_all_1.gst-plugins-base
        gst_all_1.gst-plugins-good
        gst_all_1.gst-plugins-bad
        gst_all_1.gst-plugins-ugly
        gst_all_1.gst-libav
        hicolor-icon-theme
        shared-mime-info
        gsettings-desktop-schemas
      ]);

    # WebKitGTK's DMA-BUF/compositing renderer and its internal WebProcess sandboxing
    # (a second, nested bubblewrap invocation) are both unreliable inside our own
    # buildFHSEnv bubblewrap sandbox; disable them explicitly.
    #
    # Ensure /usr/bin (and friends) are searched first, matching the app's native
    # Ubuntu environment, in case anything execs a bare command name via $PATH.
    # WebKitGTK's native Wayland compositing backend is unreliable (blank/white
    # WebView content); forcing GTK onto the X11 backend (via XWayland) is the
    # standard workaround.
    profile = ''
      export WEBKIT_DISABLE_COMPOSITING_MODE=1
      export WEBKIT_DISABLE_DMABUF_RENDERER=1
      export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
      export GDK_BACKEND=x11
      export PATH="/usr/bin:/usr/sbin:/bin:/sbin:$PATH"
      # Without this, GIO can't find glib-networking's TLS module and falls back to
      # GDummyTlsBackend, breaking every HTTPS connection (login, cloud sync, ...)
      # with "TLS support is not available".
      export GIO_EXTRA_MODULES=/usr/lib/gio/modules
      # See the workbench-zip-extraction comment in the unwrapped derivation: this
      # points the app at the Workbench SPA we extracted ourselves, bypassing the
      # broken "pages://" scheme handler.
      export ACNEXT_WORKBENCH_ENV_VAR="file:///usr/share/AnycubicSlicerNext/resources/workbench/index.html"
    '';

    # The real bug behind the blank white "Workbench"/homepage tab: the app opens its
    # local resources/web/homepage/*.html and images with O_NOATIME. The kernel only
    # allows O_NOATIME for the file's owner or a CAP_FOWNER-holding process; our
    # resources come from the (root-owned) Nix store and we run unprivileged, so every
    # such open() fails with EPERM and the embedded WebView never gets any content.
    # Work around it by mirroring resources/ into a user-owned cache directory on first
    # run (outside the sandbox, so $HOME is the real one) and bind-mounting that copy
    # over the read-only store path inside the sandbox.
    extraPreBwrapCmds = ''
      resources_src="${anycubic-slicer-next-unwrapped}/share/AnycubicSlicerNext/resources"
      resources_cache="$HOME/.cache/anycubic-slicer-next/resources"
      resources_marker="$HOME/.cache/anycubic-slicer-next/resources.src"
      if [ ! -d "$resources_cache" ] || [ "$(cat "$resources_marker" 2>/dev/null)" != "$resources_src" ]; then
        rm -rf "$resources_cache"
        mkdir -p "$resources_cache"
        cp -r "$resources_src/." "$resources_cache/"
        chmod -R u+w "$resources_cache"
        echo "$resources_src" > "$resources_marker"
      fi
    '';

    extraBwrapArgs = [
      "--bind"
      "$HOME/.cache/anycubic-slicer-next/resources"
      "/usr/share/AnycubicSlicerNext/resources"
    ];

    runScript = "AnycubicSlicerNext";
  };
in
symlinkJoin {
  name = "anycubic-slicer-next-${version}";

  paths = [ anycubic-slicer-next-fhs ];

  postBuild = ''
    mkdir -p $out/share
    ln -s ${anycubic-slicer-next-unwrapped}/share/applications $out/share/applications
    ln -s ${anycubic-slicer-next-unwrapped}/share/icons $out/share/icons
  '';

  meta = {
    description = "Anycubic Slicer Next, an OrcaSlicer-based slicer for Anycubic FDM printers";
    homepage = "https://github.com/ANYCUBIC-3D/AnycubicSlicer";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "anycubic-slicer-next";
  };
}
