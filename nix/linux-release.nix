{ pkgs
, system
, packageVersion
, artifactVersion ? packageVersion
, executableName
, package
, bundlers
}:

let
  appImage = bundlers.bundlers.${system}.toAppImage package;
  deb = bundlers.bundlers.${system}.toDEB package;
  rpm = bundlers.bundlers.${system}.toRPM package;
in
pkgs.runCommand
  "${executableName}-${artifactVersion}-${system}-artifacts"
  {
    nativeBuildInputs = [ pkgs.coreutils pkgs.findutils ];
    passthru = {
      inherit appImage deb rpm;
    };
  } ''
  mkdir -p "$out"

  cp -L ${appImage} "$out/${executableName}-${artifactVersion}-${system}.AppImage"

  deb_file="$(find ${deb} -maxdepth 1 -type f -name '*.deb' | head -1)"
  rpm_file="$(find ${rpm} -maxdepth 1 -type f -name '*.rpm' | head -1)"

  test -n "$deb_file"
  test -n "$rpm_file"

  cp "$deb_file" "$out/${executableName}-${artifactVersion}-${system}.deb"
  cp "$rpm_file" "$out/${executableName}-${artifactVersion}-${system}.rpm"

  (cd "$out" && sha256sum * > SHA256SUMS)
''
