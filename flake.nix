{
  description = "printwd build";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    inputs@{
      self,
      flake-utils,
      nixpkgs,
      zig-overlay,
    }:
    # Now eachDefaultSystem is only using ["x86_64-linux"], but this list can also
    # further be changed by users of your flake.
    let
      # Our supported systems are the same supported systems as the Zig binaries
      systems = builtins.attrNames zig-overlay.packages;
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        overlays = [
          (final: prev: rec {
            zigpkgs = zig-overlay.packages.${prev.system};
            zig = zig-overlay.packages.${prev.system}."0.16.0";
          })
        ];
        pkgs = import nixpkgs { inherit overlays system; };
        nativeBuildInputs = with pkgs; [
          pkgs.zig
          zls
        ];
        buildInputs = with pkgs; [ ];
      in
      {
        devShells.default = pkgs.mkShell { inherit nativeBuildInputs buildInputs; };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "template";
          version = "0.0.0";
          src = ./.;

          nativeBuildInputs = nativeBuildInputs ++ [ pkgs.zig.hook ];
          inherit buildInputs;
        };
      }
    );
}
