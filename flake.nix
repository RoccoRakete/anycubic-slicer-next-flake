{
  description = "Anycubic Slicer Next package flake (unofficial, packages the upstream .deb)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      anycubicSrc = {
        version = "2.0.06";
        # Taken verbatim from the APT Packages index "Filename:" field; its layout
        # changes between releases, so don't reconstruct it from parts.
        srcPath = "pool/main/a/anycubicslicernext/AnycubicSlicerNext_linux-v2.0.0.5-20260913065625.deb";
        srcHash = "sha256-/gh6VgFO0lzf5MPCk7UXra7gqbLh3tefXjlLeWiBfBU=";
      };

      anycubic-slicer-next = pkgs.callPackage ./package.nix {
        inherit (anycubicSrc)
          version
          srcPath
          srcHash
          ;
      };
    in
    {
      packages.${system} = {
        default = anycubic-slicer-next;
        anycubic-slicer-next = anycubic-slicer-next;
      };

      overlays.default = final: prev: { anycubic-slicer-next = anycubic-slicer-next; };
    };
}
