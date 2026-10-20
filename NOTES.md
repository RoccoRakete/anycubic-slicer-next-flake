# Development notes

Findings from packaging the upstream `.deb` for NixOS; last reviewed against
2.0.06. Kept for future maintainers (including future-us) in case a vendor
update shifts any of this. The bug write-ups below were first made against an
older release (1.3.96); re-check them after major vendor updates.

## Version scheme

Three different numbers describe one release. Mixing them up is the trap at
every update:

- `Version:` in the APT `Packages` index (e.g. `2.0.06`) is what lands in
  `flake.nix` as `version`.
- The `.deb` filename on the CDN carries a *different* number plus a build
  timestamp (currently
  `pool/main/a/anycubicslicernext/AnycubicSlicerNext_linux-v2.0.0.5-20260913065625.deb`,
  i.e. `v2.0.0.5-<timestamp>`). It cannot be derived from the index version.
- The real app version is reported to live inside the `.deb` at
  `resources/build-version.txt`. This comes from a third-party repackaging
  project that reads the same index; not verified here (the `.deb` was not
  unpacked for this note).

Therefore always copy `srcPath` verbatim from the index's `Filename:` field;
never assemble it from version parts. The filename layout has already changed
once (see the history note in the Workbench section, and the comment in
`flake.nix`).

## How this repo is maintained

- `update-anycubic-slicer.sh` is the only place that writes `version`,
  `srcPath` and `srcHash` in `flake.nix`. The daily workflow
  (`.github/workflows/update-slicer.yml`) runs it and pushes the result to
  `main` itself, so commits like "Update Anycubic Slicer Next to X" come from
  the bot, not from a human.
- Which workflow builds when: the update workflow builds the package only if
  `flake.nix` changed, before committing. The separate build-check workflow
  (`.github/workflows/build.yml`) runs `nix build .#default` on every push to
  `main`, every pull request, and on manual dispatch. `flake.nix` also exposes
  `checks.x86_64-linux.default` (the same package) for `nix flake check`.
- **The build downloads the `.deb` from Anycubic's CDN.** If the CDN is
  unhealthy, CI goes red although the repo is fine. This is exactly what let
  the update job die unnoticed for weeks: the global CDN
  (`cdn-universe-slicer.anycubic.com`) has served an expired TLS certificate
  since 2026-10-10. The script now uses Anycubic's second official host
  (`cdn-platform-slicer.anycubicloud.com`); keep the base URL in `package.nix`
  in sync with `repo_base` in the script. TLS verification is never disabled.
  A failing update run opens (or comments on) a GitHub issue.
- This repo is consumed by `nixcfg` (hosts `hermes` and `apollon`), pinned to a
  commit via `nixcfg`'s `flake.lock`. When consumed that way, `nixcfg`
  overrides this flake's `nixpkgs`, so the WebKitGTK/GTK versions in use are
  decided by `nixcfg`, not by the `flake.lock` here. This repo's own
  `flake.lock` only applies to `nix run github:...`. (Taken from the task
  description; the `nixcfg` repo was not available to check.)
- The package is `x86_64-linux` only.

## Why `buildFHSEnv` instead of `autoPatchelfHook`

The upstream `.deb` ships a plain Ubuntu build (no `SLIC3R_FHS`/relative-resource-path
build flag, unlike the OrcaSlicer packages in nixpkgs). `strings` on the main binary
shows the literal path `/usr/share/AnycubicSlicerNext/resources` hard-coded — not
relative to the executable. A `patchelf`-only package would need to rewrite that
string in the binary, which isn't practical (the replacement path is a different
length and the string isn't null-padded for it). `buildFHSEnv` sidesteps the whole
problem: inside the sandbox, `/usr/share/AnycubicSlicerNext/resources` really does
exist at that literal path, because we put the unwrapped derivation itself into
`targetPkgs`.

## Bugs found (all fixed in `package.nix`)

### 1. `O_NOATIME` + read-only Nix store → `EPERM` on every local resource read

The app opens its own bundled HTML/CSS/JS/images (under `resources/`) with the
`O_NOATIME` flag. Linux only allows `O_NOATIME` for the file's owner or a
`CAP_FOWNER`-holding process. Nix store paths are owned by `root`; we run as a
normal user → every such `open()` fails with `EPERM`, silently, and the embedded
WebView never gets any content (blank white).

**Fix:** `extraPreBwrapCmds` mirrors `resources/` into `~/.cache/anycubic-slicer-next/resources`
(a real, user-owned directory, created *outside* the sandbox so `$HOME` is genuine)
on first run, then `extraBwrapArgs` bind-mounts that copy over the read-only
store path inside the sandbox. Cache is invalidated automatically by comparing
a marker file against the current store path, so it re-copies after every
`nix build`/update.

Found via `strace -f -e trace=openat` while clicking around the UI — the failing
opens showed up as `= -1 EPERM` for paths under `resources/web/homepage/`.

### 2. Missing GIO TLS backend → "TLS support is not available"

`glib-networking`'s GIO module (`libgiognutls.so`) wasn't on `GIO_EXTRA_MODULES`,
so GIO silently fell back to `GDummyTlsBackend` and every HTTPS connection
(login, cloud sync) failed with that exact message shown in a popup.

**Fix:** `export GIO_EXTRA_MODULES=/usr/lib/gio/modules` in the FHS `profile`.
(`/usr/lib` is a symlink to `/usr/lib64` inside the sandbox rootfs — looks like a
dead end with a plain `find` unless you pass `-L`.)

### 3. WebKitGTK sandboxing/compositing conflicts with our own `bwrap` sandbox

Symptoms: repeated `WebKitWebProcess`/`WebKitNetworkProcess` churn, occasional
"Permission denied" trying to re-exec itself. WebKitGTK's own internal
bubblewrap-based process sandboxing doesn't nest cleanly inside our
`buildFHSEnv` bubblewrap sandbox.

**Fix:**
```
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
export GDK_BACKEND=x11
```
(`GDK_BACKEND=x11` forces XWayland instead of WebKitGTK's native Wayland backend,
which has had various compositing bugs.)

### 4. The big one: `libWorkbench.so`'s `registerHandler()` is a no-op stub

The "Workbench" tab (device/cloud printer management — login, add printer, video
monitor) stayed blank even after every environment-level fix above, and even
though the exact same HTML rendered fine when loaded directly with a standalone
WebKitGTK test program in the same sandbox. Root-caused by:

- `objdump -d` on `libWorkbench.so`: the exported `registerHandler` function is
  literally `endbr64; ret` — 5 bytes, does nothing with its arguments.
- `gdb` breakpoints on `webkit_uri_scheme_request_finish` /
  `_finish_error` never fire when the tab is clicked, confirming the custom
  `pages://` URI scheme handler (registered elsewhere in the closed-source main
  binary, not in `libWorkbench.so`) never gets a response to serve.
- The *content* is not missing: `libWorkbench.so`'s `.rodata` contains a small
  header (`"Workbench\0" + <md5 hex>\0`) immediately followed by a complete,
  valid ZIP (starts at the `PK\x03\x04` signature) with a full Vue.js SPA —
  `index.html`, `js/src_views_workbench_Workbench_vue.js`,
  `js/src_views_login_LoginPage_vue.js`, `webrtcstreamer.js`, fonts, images of
  every printer model, etc. `unzip -t` reports zero CRC errors.
- The public source at github.com/ANYCUBIC-3D/AnycubicSlicerNext (OrcaSlicer
  fork) contains **no** reference to `Workbench`, `registerHandler`,
  `pages://`, or `webkit_web_context_register_uri_scheme` anywhere — this
  feature is 100% closed-source, layered on top of the public tree at build
  time.
- `strings` on the main binary turned up `ACNEXT_WORKBENCH_ENV_VAR` (and
  `ACNEXT_HOMEPAGE_ENV_VAR`) — an internal developer/debug override read via
  `getenv()`. Setting it to a `file://` URL pointing at a manually-extracted
  copy of the embedded SPA makes the Workbench tab render perfectly, bypassing
  the broken `pages://` handler entirely.

**Fix:** in the unwrapped derivation's `installPhase`, find the ZIP's start
offset with `grep -abo $'PK\x03\x04'` (robust against header-size changes in
future vendor builds, unlike a hard-coded byte offset) and `unzip` it into
`resources/workbench/` (inside the `resources/` tree so it rides along with the
`O_NOATIME` cache-copy fix above for free). Then:
```
export ACNEXT_WORKBENCH_ENV_VAR="file:///usr/share/AnycubicSlicerNext/resources/workbench/index.html"
```

This is very likely shipping *broken for everyone*, not just under Nix.
Historical observation (1.3.96 era): the `.deb`'s filename literally started
with `develop_` and had been sitting unchanged in the "prod" APT repo for
months. That filename no longer exists (since commit `4045ee2` the index points
at `pool/main/a/anycubicslicernext/AnycubicSlicerNext_linux-v2.0.0.5-*.deb`), so
re-check whether the stub is still present in the current build before relying
on this reasoning. A user's already-installed Ubuntu
system might be running an older/different binary from before this regression,
which would explain "works on Ubuntu" reports without contradicting any of the
above.

## Dead ends (tried, ruled out, don't repeat)

- **Pinning `nixpkgs` to `nixos-24.11`** to match Ubuntu 24.04's exact
  `webkitgtk_4_1` (2.48.3, matching the `.deb`'s declared `>= 2.48.0` dependency)
  and closer `gtk3` (3.24.43 vs. Ubuntu's 3.24.41). Made things *worse* (gray
  screen, broke the previously-working Home tab too). Reverted to
  `nixos-unstable`. The recurring `Gtk-CRITICAL` widget-sizing assertions
  (`gtk_widget_set_size_request`, `gtk_window_resize`) persisted identically on
  both channels and turned out to be unrelated to the Workbench bug.
- **Region selection in the official installer script** (China vs. Global apt
  repo) — both mirrors serve byte-identical `.deb` files (same
  MD5/SHA256/SHA1). No effect on app behavior; the region prompt only picks the
  apt source URL.
- **Login/account state** — confirmed via the user that the Workbench tab
  "worked" on their Ubuntu install *without* being logged in, so a bundled
  device/session precondition was never the blocker.
- **`/tmp/AnycubicSlicerNext/` and similar missing-directory theories** — some
  `ENOENT`s for optional cache paths (`logcacht.txt`, `WebKitCache`,
  `serviceworkers/Scripts`, an OTA changelog file) are real but harmless
  first-run conditions, not the cause of the blank tab. Pre-creating them
  changed nothing.
- **WebKit remote inspector** (`WEBKIT_INSPECTOR_SERVER=host:port`) — connects
  but returns an empty HTTP reply for a plain `curl`/browser GET; this specific
  WebKitGTK build's remote inspector protocol isn't a simple REST endpoint, so
  it's a dead end for casual debugging (confirmed with a minimal native
  WebKitGTK test program too, so it's not sandbox-specific).

## Useful debugging techniques for this kind of proprietary-binary packaging

- **`webkit_web_view_get_snapshot()` via a small custom GTK+WebKitGTK test
  program** compiled with `nix-shell -p gtk3 webkitgtk_4_1 pkg-config gcc` is a
  fast way to check "does this exact HTML/JS render correctly *at all* in this
  exact environment" without needing a full desktop screenshot — write a PNG,
  read it back. Can be run both natively and re-pointed at
  `file:///usr/share/...` paths inside a purpose-built `buildFHSEnv` copy of the
  real sandbox for apples-to-apples comparison.
- **`gdb -p <pid>` attached to the already-running app**, breaking on public
  WebKitGTK API symbols (`webkit_web_view_load_uri`,
  `webkit_web_context_register_uri_scheme`, `webkit_uri_scheme_request_finish[_error]`)
  reveals real navigation URLs and scheme registrations without needing any
  debug symbols in the target — these resolve fine off the shared library's
  own dynamic symbol table.
  - `pgrep -f AnycubicSlicerNext` self-matches your own shell command line if
    it contains that string (e.g. in a heredoc). Use `pgrep -x AnycubicSlicerN`
    (Linux's `comm` field truncates to 15 chars) instead.
  - Attaching *too early* (right at process start) can transiently race another
    tracer; poll for the PID and retry rather than using a fixed sleep.
- **`xdotool` + `xwd`/`convert`** (not ImageMagick 7's `import`, which errors
  out under this sandbox/policy setup) to screenshot a specific window by ID for
  fast visual iteration without needing the user to test every change.
- **`objdump -d -M intel`** on a suspiciously tiny/data-heavy `.so`
  (`readelf -S` showing `.text` a few hundred bytes vs. `.rodata` tens of MB) is
  worth doing early if a "plugin" library is involved — it may just be an
  embedded-data container with a stub loader, not real code.
