{
  description = "A Nix-based continuous build system";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";

  inputs.lix.url = "git+https://git.lix.systems/lix-project/lix";
  inputs.lix.inputs.nixpkgs.follows = "nixpkgs";

  inputs.nix-eval-jobs.url = "git+https://git.lix.systems/lix-project/nix-eval-jobs";
  inputs.nix-eval-jobs.inputs.nixpkgs.follows = "nixpkgs";
  inputs.nix-eval-jobs.inputs.lix.follows = "lix";

  outputs = { self, nix-eval-jobs, nixpkgs, lix }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;

      overlayList = [ self.overlays.default lix.overlays.default ];

      pkgsBySystem = forEachSystem (system: import nixpkgs {
        inherit system;
        overlays = overlayList;
      });

    in
    rec {

      # A Nixpkgs overlay that provides a 'hydra' package.
      overlays.default = final: prev: {
        hydra = final.callPackage ./package.nix {
          inherit (final.lib) fileset;
          nix-eval-jobs = nix-eval-jobs.packages.${final.system}.default;
          rawSrc = self;
        };
      };

      hydraJobs = {

        build = forEachSystem (system: packages.${system}.hydra);

        buildNoTests = forEachSystem (system:
          packages.${system}.hydra.overrideAttrs (_: {
            doCheck = false;
          })
        );

        manual = forEachSystem (system:
          let pkgs = pkgsBySystem.${system}; in
          pkgs.runCommand "hydra-manual-${pkgs.hydra.version}" { }
            ''
              mkdir -p $out/share
              cp -prvd ${pkgs.hydra}/share/doc $out/share/

              mkdir $out/nix-support
              echo "doc manual $out/share/doc/hydra" >> $out/nix-support/hydra-build-products
            '');

        tests = import ./nixos-tests.nix {
          inherit forEachSystem nixpkgs pkgsBySystem nixosModules;
        };

        container = nixosConfigurations.container.config.system.build.toplevel;
      };

      checks = forEachSystem (system: {
        build = hydraJobs.build.${system};
        install = hydraJobs.tests.install.${system};
        validate-openapi = hydraJobs.tests.validate-openapi.${system};
      });

      packages = forEachSystem (system: {
        hydra = pkgsBySystem.${system}.hydra;
        default = pkgsBySystem.${system}.hydra;
      });

      devShells = forEachSystem (system: let
        pkgs = pkgsBySystem.${system};
        lib = pkgs.lib;

        mkDevShell = stdenv: (pkgs.mkShell.override { inherit stdenv; }) {
          inputsFrom = [ (self.packages.${system}.default.override { inherit stdenv; }) ];

          packages =
            lib.optional (stdenv.cc.isClang && stdenv.hostPlatform == stdenv.buildPlatform) pkgs.clang-tools;
        };
      in {
        default = mkDevShell pkgs.stdenv;
        clang = mkDevShell pkgs.clangStdenv;
      });

      nixosModules = import ./nixos-modules {
        overlays = overlayList;
      };

      nixosConfigurations.container = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules =
          [
            self.nixosModules.hydra
            self.nixosModules.overlayNixpkgsForThisHydra
            self.nixosModules.hydraTest
            self.nixosModules.hydraProxy
            {
              system.configurationRevision = self.lastModifiedDate;

              boot.isContainer = true;
              networking.useDHCP = false;
              networking.firewall.allowedTCPPorts = [ 80 ];
              networking.hostName = "hydra";

              services.hydra-dev.useSubstitutes = true;
            }
          ];
      };

    };
}
