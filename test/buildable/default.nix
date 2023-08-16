{ stdenv, lib, cabalProject', haskellLib, recurseIntoAttrs, testSrc, compiler-nix-name, evalPackages, buildPackages }:

with lib;

let
  project = cabalProject' {
    inherit compiler-nix-name evalPackages;
    src = testSrc "buildable";
    modules = [ { packages.buildable-test.flags.exclude-broken = true; } ];
  };
  packages = project.hsPkgs;

in recurseIntoAttrs {
  ifdInputs = {
    inherit (project) plan-nix;
  };
  run = stdenv.mkDerivation {
    name = "buildable-test";

    buildCommand =
      (concatStrings (mapAttrsToList (name: value: ''
        printf "checking whether executable runs... " >& 2
        cat ${haskellLib.check value}/test-stdout
      '') packages.buildable-test.components.exes)) + ''
      touch $out
    '';

    meta = rec {
      platforms = lib.platforms.all;
      broken = stdenv.hostPlatform.isGhcjs && __compareVersion buildPackages.haskell-nix.compiler.${compiler-nix-name}.version "9.6.1" >= 0;
      disabled = broken;
    };

    passthru = {
      # Attributes used for debugging with nix repl
      inherit project packages;
    };
  };
}
