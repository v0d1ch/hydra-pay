{}:
let pkgs = (import ./. {}).obelisk.nixpkgs;
in
  pkgs.mkShell {
    name = "hydra-pay";
    buildInputs = [
      pkgs.gmp
    ];
    inputsFrom = [
      (import ./. {}).shells.ghc
    ];
  }
