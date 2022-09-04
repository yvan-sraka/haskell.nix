# Test building TH code that needs DLLs when cross compiling for windows
{ stdenv, lib, util, project', haskellLib, recurseIntoAttrs, testSrc, compiler-nix-name, evalPackages }:

with lib;

let
  project = project' {
    inherit compiler-nix-name evalPackages;
    src = testSrc "th-dlls";
    pkgconfSelector = p: [p.libsodium];
  };

  packages = project.hsPkgs;

in recurseIntoAttrs {
  meta.disabled = stdenv.hostPlatform.isGhcjs;

  ifdInputs = {
    inherit (project) plan-nix;
  };

  build = packages.th-dlls.components.library;
  build-profiled = packages.th-dlls.components.library.profiled;
  just-template-haskell = packages.th-dlls.components.exes.just-template-haskell;
}
