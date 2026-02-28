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
    # TODO: Run `nix-prefetch-url --unpack https://github.com/edolstra/flake-compat/archive/5edf11c44bc78a0d334f6334cdaf7d60d732daab.tar.gz`
    # and replace this placeholder with the correct sha256 hash.
    sha256 = "0000000000000000000000000000000000000000000000000000";
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
        (self: super: {
          reflex-gadt-api = self.callCabal2nix "reflex-gadt-api" deps.reflex-gadt-api {};
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
