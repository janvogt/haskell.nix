{ stdenv, ghc, lib, pkgconfig, writeText, runCommand, haskellLib, nonReinstallablePkgs }:

{ componentId
, component
, package
, name
, setup
, src
, flags
, cabalFile
, patches ? []
, postUnpack ? null
}:

let
  fullName = "${name}-${componentId.ctype}-${componentId.cname}";

  flagsAndConfig = field: xs: lib.optionalString (xs != []) ''
    echo ${lib.concatStringsSep " " (map (x: "--${field}=${x}") xs)} >> $out/configure-flags
    echo "${field}: ${lib.concatStringsSep " " xs}" >> $out/cabal.config
  '';

  flatDepends =
    let
      makePairs = map (p: rec { key="${val}"; val=p.components.library; });
      closure = builtins.genericClosure {
        startSet = makePairs component.depends;
        operator = {val,...}: makePairs val.config.depends;
      };
    in map ({val,...}: val) closure;

  exactDep = pdbArg: p: ''
    if id=$(${ghc.targetPrefix}ghc-pkg ${pdbArg} field ${p} id --simple-output); then
      echo "--dependency=${p}=$id" >> $out/configure-flags
    fi
    if ver=$(${ghc.targetPrefix}ghc-pkg ${pdbArg} field ${p} version --simple-output); then
      echo "constraint: ${p} == $ver" >> $out/cabal.config
      echo "constraint: ${p} installed" >> $out/cabal.config
    fi
  '';

  configFiles = runCommand "${fullName}-config" { nativeBuildInputs = [ghc]; } (''
    mkdir -p $out
    ${ghc.targetPrefix}ghc-pkg init $out/package.conf.d

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList flagsAndConfig {
      "extra-lib-dirs" = map (p: "${lib.getLib p}/lib") component.libs;
      "extra-include-dirs" = map (p: "${lib.getDev p}/include") component.libs;
      "extra-framework-dirs" = map (p: "${p}/Library/Frameworks") component.frameworks;
    })}

    # Copy over the nonReinstallablePkgs from the global package db.
    # Note: we need to use --global-package-db with ghc-pkg to prevent it
    #       from looking into the implicit global package db when registering the package.
    ${lib.concatMapStringsSep "\n" (p: ''
      ${ghc.targetPrefix}ghc-pkg describe ${p} | ${ghc.targetPrefix}ghc-pkg --force --global-package-db $out/package.conf.d register - || true
    '') nonReinstallablePkgs}

    ${lib.concatMapStringsSep "\n" (p: ''
      ${ghc.targetPrefix}ghc-pkg --package-db ${p}/package.conf.d dump | ${ghc.targetPrefix}ghc-pkg --force --package-db $out/package.conf.d register -
    '') flatDepends}

    # Note: we pass `clear` first to ensure that we never consult the implicit global package db.
    ${flagsAndConfig "package-db" ["clear" "$out/package.conf.d"]}

    echo ${lib.concatStringsSep " " (lib.mapAttrsToList (fname: val: "--flags=${lib.optionalString (!val) "-" + fname}") flags)} >> $out/configure-flags

  '' + lib.optionalString component.doExactConfig ''
    echo "--exact-configuration" >> $out/configure-flags
    echo "allow-newer: ${package.identifier.name}:*" >> $out/cabal.config
    echo "allow-older: ${package.identifier.name}:*" >> $out/cabal.config

    ${lib.concatMapStringsSep "\n" (p: exactDep "--package-db ${p.components.library}/package.conf.d" p.identifier.name) component.depends}
    ${lib.concatMapStringsSep "\n" (exactDep "") nonReinstallablePkgs}

  ''
  # This code originates in the `generic-builder.nix` from nixpkgs.  However GHC has been fixed
  # to drop unused libraries referneced from libraries; and this patch is usually included in the
  # nixpkgs's GHC builds.  This doesn't sadly make this stupid hack unnecessary.  It resurfes in
  # the form of Cabal trying to be smart. Cabal when linking a library figures out that you likely
  # need those `rpath` entries, and passes `-optl-Wl,-rpath,...` for each dynamic library path to
  # GHC, thus subverting the linker and forcing it to insert all those RPATHs weather or not they
  # are needed.  We therfore reuse the linker hack here to move all al dynamic lirbaries into a
  # common folder (as links) and thus prevent Cabal from going nuts.
  #
  # TODO: Fix Cabal.
  # TODO: this is only needed if we do dynamic libraries.
  + lib.optionalString stdenv.isDarwin ''
    # Work around a limit in the macOS Sierra linker on the number of paths
    # referenced by any one dynamic library:
    #
    # Create a local directory with symlinks of the *.dylib (macOS shared
    # libraries) from all the dependencies.
    local dynamicLinksDir="$out/lib/links"
    mkdir -p $dynamicLinksDir
    for d in $(grep dynamic-library-dirs "$out/package.conf.d/"*|awk '{print $2}'|sort -u); do
      ln -s "$d/"*.dylib $dynamicLinksDir
    done
    # Edit the local package DB to reference the links directory.
    for f in "$out/package.conf.d/"*.conf; do
      sed -i "s,dynamic-library-dirs: .*,dynamic-library-dirs: $dynamicLinksDir," $f
    done
  '' + ''
    ${ghc.targetPrefix}ghc-pkg --package-db $out/package.conf.d recache
  '' + ''
    ${ghc.targetPrefix}ghc-pkg --package-db $out/package.conf.d check
  '');

  finalConfigureFlags = lib.concatStringsSep " " (
    [ "--prefix=$out"
      "${componentId.ctype}:${componentId.cname}"
      "$(cat ${configFiles}/configure-flags)"
      "--with-ghc=${ghc.targetPrefix}ghc"
      "--with-ghc-pkg=${ghc.targetPrefix}ghc-pkg"
      "--with-hsc2hs=${ghc.targetPrefix}hsc2hs"
    ] ++ lib.optionals (stdenv.hostPlatform != stdenv.buildPlatform) (
      ["--hsc2hs-option=--cross-compile"]
      ++ lib.optional (package.buildType == "Configure") "--configure-option=--host=${stdenv.hostPlatform.config}"
    ) ++ component.configureFlags
  );

in stdenv.mkDerivation ({
  name = fullName;

  inherit src;

  doCheck = componentId.ctype == "test";

  passthru = {
    inherit (package) identifier;
    config = component;
    inherit configFiles;
  };

  meta = {
    homepage = package.homepage;
    description = package.synopsis;
    license = (import ../lib/cabal-licenses.nix lib).${package.license};
  };

  CABAL_CONFIG = configFiles + /cabal.config;

  enableParallelBuilding = true;

  buildInputs = component.libs
    ++ component.pkgconfig;

  nativeBuildInputs =
    [ghc]
    ++ lib.optional (component.pkgconfig != []) pkgconfig
    ++ lib.concatMap (c: if c.isHaskell or false
      then builtins.attrValues (c.components.exes or {})
      else [c]) component.build-tools;

  SETUP_HS = setup + /bin/Setup;

  # Phases
  prePatch = lib.optionalString (cabalFile != null) ''
    cat ${cabalFile} > ${package.identifier.name}.cabal
  '';

  configurePhase = ''
    echo Configure flags:
    printf "%q " ${finalConfigureFlags}
    echo
    $SETUP_HS configure ${finalConfigureFlags}
  '';

  buildPhase = ''
    $SETUP_HS build -j$NIX_BUILD_CORES ${lib.concatStringsSep " " component.setupBuildFlags}
  '';

  checkPhase = ''
    $SETUP_HS test
  '';

  installPhase = ''
    $SETUP_HS copy
    ${lib.optionalString (haskellLib.isLibrary componentId) ''
      $SETUP_HS register --gen-pkg-config=${name}.conf
      ${ghc.targetPrefix}ghc-pkg init $out/package.conf.d
      ${ghc.targetPrefix}ghc-pkg --package-db ${configFiles}/package.conf.d -f $out/package.conf.d register ${name}.conf
    ''}
  '';
}
// lib.optionalAttrs (patches != []) { inherit patches; }
// lib.optionalAttrs (postUnpack != null) { inherit postUnpack; }
)
