{
  stdenv,
  cosmopolitan,
  python312,
  zip,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "werehouse";
  version = "1.2.1";

  src = ./.;

  nativeBuildInputs = [
    cosmopolitan
    zip
    (python312.withPackages (ps: [
      ps.htmlmin
    ]))
  ];

  dontCheck = true;
  dontPatch = true;
  dontConfigure = true;
  dontFixup = true;

  buildPhase = ''
    runHook preBuild

    cp "${cosmopolitan}/bin/redbean" ./redbean-3.0beta.com
    ls .
    make build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    install werehouse.com $out/bin

    runHook postInstall
  '';
})
