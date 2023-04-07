{
  description = "Build a cargo project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-analyzer-src.follows = "";
    };

    flake-utils.url = "github:numtide/flake-utils";

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, crane, fenix, flake-utils, advisory-db, ... }: {
    formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixpkgs-fmt;
  } //
  #               👇 this used to be  eachDefaultSystem but now we build only on linux!
  flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
    let
      pkgs = import nixpkgs {
        inherit system;
      };


      inherit (pkgs) lib;

      craneLib = crane.lib.${system};
      src = craneLib.cleanCargoSource (craneLib.path ./.);

      # Common arguments can be set here to avoid repeating them later
      commonArgs = {
        inherit src;

        buildInputs = [
          # Add additional build inputs here
        ];

        # Additional environment variables can be set directly
        # MY_CUSTOM_VAR = "some value";
      };

      craneLibLLvmTools = craneLib.overrideToolchain
        (fenix.packages.${system}.complete.withComponents [
          "cargo"
          "llvm-tools"
          "rustc"
        ]);

      # Build *just* the cargo dependencies, so we can reuse
      # all of that work (e.g. via cachix) when running in CI
      cargoArtifacts = craneLib.buildDepsOnly commonArgs;

      # Build the actual crate itself, reusing the dependency
      # artifacts from above.
      my-crate = craneLib.buildPackage (commonArgs // {
        inherit cargoArtifacts;
      });

    in
    {
      nixosModules.default = { config, lib, ... }: with lib;
        let
          cfg = config.services.backend;
        in
        {
          options.services.backend = {
            enable = mkEnableOption "Enables the backend HTTP service";

            domain = mkOption rec {
              type = types.str;
              default = "localhost";
              example = default;
              description = "The domain name";
            };
          };

          config = mkIf cfg.enable {
            systemd.services.backend = {
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                Restart = "on-failure";
                ExecStart = "${my-crate}/bin/quick-start";
                DynamicUser = "yes";
                RuntimeDirectory = "backend";
                RuntimeDirectoryMode = "0755";
                StateDirectory = "backend";
                StateDirectoryMode = "0700";
                CacheDirectory = "backend";
                CacheDirectoryMode = "0750";
              };
            };

            services.nginx.virtualHosts.${cfg.domain} = {
              locations."/" = { proxyPass = "http://127.0.0.1:3000"; };
            };
          };
        };
      checks = {
        # Build the crate as part of `nix flake check` for convenience
        inherit my-crate;

        # Run clippy (and deny all warnings) on the crate source,
        # again, resuing the dependency artifacts from above.
        #
        # Note that this is done as a separate derivation so that
        # we can block the CI if there are issues here, but not
        # prevent downstream consumers from building our crate by itself.
        my-crate-clippy = craneLib.cargoClippy (commonArgs // {
          inherit cargoArtifacts;
          cargoClippyExtraArgs = "--all-targets -- --deny warnings";
        });

        my-crate-doc = craneLib.cargoDoc (commonArgs // {
          inherit cargoArtifacts;
        });

        # Check formatting
        my-crate-fmt = craneLib.cargoFmt {
          inherit src;
        };

        # Audit dependencies
        my-crate-audit = craneLib.cargoAudit {
          inherit src advisory-db;
        };

        # Run tests with cargo-nextest
        # Consider setting `doCheck = false` on `my-crate` if you do not want
        # the tests to run twice
        my-crate-nextest = craneLib.cargoNextest (commonArgs // {
          inherit cargoArtifacts;
          partitions = 1;
          partitionType = "count";
        });


        integration = import ./nixos-test.nix {
          makeTest = import (nixpkgs + "/nixos/tests/make-test-python.nix");
          inherit system;
          inherit pkgs;
          inherit self;
        };

        my-crate-coverage = craneLib.cargoTarpaulin (commonArgs // {
          inherit cargoArtifacts;
        });
      };

      packages = {
        default = my-crate;
        my-crate-llvm-coverage = craneLibLLvmTools.cargoLlvmCov (commonArgs // {
          inherit cargoArtifacts;
        });
      };


      apps.default = flake-utils.lib.mkApp {
        drv = my-crate;
      };


      devShells.default = pkgs.mkShell {
        inputsFrom = builtins.attrValues self.checks.${system};

        # Additional dev-shell environment variables can be set directly
        # MY_CUSTOM_DEVELOPMENT_VAR = "something else";

        # Extra inputs can be added here
        nativeBuildInputs = with pkgs; [
          cargo
          rustc
        ];
      };
    });

}
