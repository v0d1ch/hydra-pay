{ system ? builtins.currentSystem
, obelisk ? import ./.obelisk/impl {
    inherit system;
    iosSdkVersion = "13.2";

    # You must accept the Android Software Development Kit License Agreement at
    # https://developer.android.com/studio/terms in order to build Android apps.
    # Uncomment and set this to `true` to indicate your acceptance:
    config.android_sdk.accept_license = true;

    # In order to use Let's Encrypt for HTTPS deployments you must accept
    # their terms of service at https://letsencrypt.org/repository/.
    # Uncomment and set this to `true` to indicate your acceptance:
    terms.security.acme.acceptTerms = true;
  }
}:
with obelisk;
let
  foldExtensions = lib.foldr lib.composeExtensions (_: _: {});
  deps = obelisk.nixpkgs.thunkSet ./dep;

  # Hydra 1.2.0 uses Nix flakes, so we use flake-compat to import it
  # as a traditional Nix expression.
  flake-compat = import (builtins.fetchTarball {
    url = "https://github.com/edolstra/flake-compat/archive/5edf11c44bc78a0d334f6334cdaf7d60d732daab.tar.gz";
    sha256 = "0yqfa6rx8md81bcn4szfp0hjq2f3h9i8zjzhqqyfqdkrj5559nmw";
  });
  hydra = (flake-compat { src = deps.hydra; }).defaultNix;

  cardano-node = import deps.cardano-node {};

  pkgs = obelisk.nixpkgs;
  livedoc-devnet-script = pkgs.runCommand "livedoc-devnet-script" { } ''
    cp -r ${./livedoc-devnet} $out
  '';
  p = project ./. ({ pkgs, ... }:
    let
      haskellLib = pkgs.haskell.lib;
    in
    {
      android.applicationId = "systems.obsidian.obelisk.examples.minimal";
      android.displayName = "Obelisk Minimal Example";
      ios.bundleIdentifier = "systems.obsidian.obelisk.examples.minimal";
      ios.bundleName = "Obelisk Minimal Example";

      overrides = foldExtensions [
        # Ensure libgmp and libffi are available for all Haskell package builds
        # (needed by integer-gmp and GHC runtime during TH evaluation and linking).
        # librarySystemDepends adds gmp to link-time flags, but the
        # ./Setup binary also needs libgmp.so.10 and libffi.so.8 at runtime, so we
        # export LD_LIBRARY_PATH in postPatch (before compileBuildDriverPhase).
        (self: super: {
          mkDerivation = args: super.mkDerivation (args // {
            librarySystemDepends = (args.librarySystemDepends or []) ++ [ pkgs.gmp ];
            postPatch = (args.postPatch or "") + ''
              export LD_LIBRARY_PATH=${pkgs.gmp}/lib:${pkgs.libffi}/lib''${LD_LIBRARY_PATH:+:}''${LD_LIBRARY_PATH:-}
            '';
          });
        })
        (self: super: {
          reflex-gadt-api = haskellLib.doJailbreak (self.callCabal2nix "reflex-gadt-api" deps.reflex-gadt-api {});
          string-interpolate = haskellLib.doJailbreak (haskellLib.dontCheck super.string-interpolate);

          backend = haskellLib.overrideCabal super.backend (drv: {
            librarySystemDepends = (drv.librarySystemDepends or []) ++ [
              cardano-node.cardano-node
              cardano-node.cardano-cli
              hydra.packages.${system}.hydra-node
              pkgs.jq
              pkgs.coreutils
              livedoc-devnet-script
            ];
          });
        })
      ];
    });

  hydra-pay-exe = pkgs.runCommandNoCC "hydra-pay" {} ''
    mkdir -p $out
    cp -r ${p.exe}/* $out/
    mv $out/backend $out/hydra-pay
  '';

in
p // {  exe = hydra-pay-exe; }
