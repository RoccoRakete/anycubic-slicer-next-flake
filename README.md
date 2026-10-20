# anycubic-slicer-next-flake

Unofficial Nix flake for [Anycubic Slicer Next](https://github.com/ANYCUBIC-3D/AnycubicSlicer)
on NixOS. Anycubic only distributes the slicer as a proprietary `.deb` for Ubuntu 24.04; this
flake downloads the official package and makes it runnable on NixOS via an FHS sandbox
(`buildFHSEnv`), since the binary has its resource path hard-coded to
`/usr/share/AnycubicSlicerNext/resources`.

Platform: `x86_64-linux` only (no aarch64).

## Usage

```sh
nix run github:roccorakete/anycubic-slicer-next-flake
```

Or add it as an overlay/package to your own configuration:

```nix
{
  inputs.anycubic-slicer-next.url = "github:roccorakete/anycubic-slicer-next-flake";

  # e.g. in environment.systemPackages:
  environment.systemPackages = [ inputs.anycubic-slicer-next.packages.x86_64-linux.default ];
}
```

## License

The slicer itself is closed-source software by Anycubic (`lib.licenses.unfree`). This flake
contains none of the slicer's code — it downloads the official `.deb` from Anycubic's CDN at
build time.

## Updating the version

```sh
./update-anycubic-slicer.sh
```

The script queries Anycubic's APT index, determines the version/hash of the latest `.deb`, and
updates `flake.nix` accordingly. The same script also runs automatically every day in a
GitHub Actions workflow, which commits and pushes any change to `main`.

## Notes

See [NOTES.md](NOTES.md) for the packaging bugs found and fixed along the way (including a
closed-source vendor plugin shipping as a no-op stub) and the debugging techniques used.
