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
        version = "1.3.96";
        # Taken verbatim from the APT Packages index "Filename:" field; its layout
        # changes between releases, so don't reconstruct it from parts.
        srcPath = "dists/noble/main/binary-amd64/develop_AnycubicSlicerNext-1.3.96_20260319_224609-Ubuntu_24_04_3_LTS.deb";
        srcHash = "sha256-LCiDqcYkq2TnIaAhFmeFLgCD2HlPeDnB15Msn3Eu0HY=";
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
