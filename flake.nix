{
  description = "ESP32 CSI room sensing demo with Zig firmware";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    esp-dev.url = "github:mirrexagon/nixpkgs-esp-dev";
    zcov = {
      url = "github:ericsssan/zcov";
      flake = false;
    };
    zls.url = "github:zigtools/zls/master";
  };

  outputs = { nixpkgs, zls, esp-dev, zcov, ... }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = function:
        builtins.listToAttrs (map
          (system: {
            name = system;
            value = function system;
          })
          supportedSystems);
      zigSources = {
        x86_64-linux = {
          url = "https://github.com/kassane/zig-espressif-bootstrap/releases/download/0.17.0-xtensa-dev/zig-relsafe-x86_64-linux-musl-baseline.tar.xz";
          hash = "sha256-5EaQJ74LDdar6oFfBc/ZZ49Kh+n3KGh1CokZA3G9iPI=";
        };
        aarch64-linux = {
          url = "https://github.com/kassane/zig-espressif-bootstrap/releases/download/0.17.0-xtensa-dev/zig-relsafe-aarch64-linux-musl-baseline.tar.xz";
          hash = "sha256-6mbHxfTfqHcsd2d7ZzIm4nZ4jYnScHjaBAeTZW7tsnQ=";
        };
        aarch64-darwin = {
          url = "https://github.com/kassane/zig-espressif-bootstrap/releases/download/0.17.0-xtensa-dev/zig-relsafe-aarch64-macos-baseline.tar.xz";
          hash = "sha256-NncNcPDankC6Z/2G8f6CjECSm12WN0dkG+nVq8iie3A=";
        };
      };
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          pnpm = pkgs.pnpm.override { nodejs-slim = pkgs.nodejs-slim_26; };
          esp-idf = esp-dev.packages.${system}.esp-idf-xtensa.overrideAttrs (old: {
            installPhase = ''
              export GIT_CONFIG_NOSYSTEM=1
            '' + old.installPhase;
          });
          zig-xtensa = pkgs.stdenv.mkDerivation {
            pname = "zig-xtensa";
            version = "0.17.0-xtensa";
            src = pkgs.fetchurl zigSources.${system};
            dontConfigure = true;
            dontBuild = true;
            dontFixup = true;
            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin" "$out/lib" "$out/doc"
              cp zig "$out/bin/"
              cp -r lib/. "$out/lib/"
              cp -r doc/. "$out/doc/"
              runHook postInstall
            '';
          };
          zig-cov = pkgs.stdenv.mkDerivation {
            pname = "zig-cov";
            version = "0.1.0";
            src = zcov;
            nativeBuildInputs = [ zig-xtensa ];
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
              zig build install -Doptimize=ReleaseSafe --prefix "$out"
              runHook postInstall
            '';
          };
          corePackages = [
            pkgs.codebook
            pkgs.nodejs_26
            pnpm
            esp-idf
            zig-xtensa
            zig-cov
          ];
          nativeLibraryPath = pkgs.lib.makeLibraryPath (
            pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.stdenv.cc.cc.lib
          );
        in
        {
          setup = pkgs.mkShell {
            packages = corePackages;
            LD_LIBRARY_PATH = nativeLibraryPath;
          };
          default = pkgs.mkShell {
            packages = corePackages ++ [
              pkgs.nixd
              zls.packages.${system}.zls
            ];
            LD_LIBRARY_PATH = nativeLibraryPath;
            shellHook = ''
              echo "ESP32 CSI environment: ESP-IDF $(idf.py --version | sed 's/^ESP-IDF //'), Zig $(zig version), Node.js $(node --version), pnpm $(pnpm --version)"
            '';
          };
        });
    };
}
