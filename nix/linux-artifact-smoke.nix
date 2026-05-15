{ pkgs, system }:

pkgs.writeShellApplication {
  name = "linux-artifact-smoke";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnugrep
    pkgs.dpkg
    pkgs.rpm
    pkgs.cpio
  ];
  text = ''
    set -euo pipefail

    usage() {
      cat <<'USAGE'
    Usage: linux-artifact-smoke
        --artifacts-dir DIR
        --artifact-version VERSION
        --executable-name NAME
        [--usage-grep STRING]

    Extracts and smoke-tests the AppImage, DEB, and RPM artifacts
    for the executable named NAME.

    --usage-grep is an additional substring the binary's diagnostic
    output (when invoked with no args) MUST contain. Defaults to the
    empty string (only "Usage:" is required).
    USAGE
    }

    artifacts_dir=""
    artifact_version=""
    system_suffix="${system}"
    executable_name=""
    usage_grep=""

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --artifacts-dir)
          artifacts_dir="$2"
          shift 2
          ;;
        --artifact-version)
          artifact_version="$2"
          shift 2
          ;;
        --system-suffix)
          system_suffix="$2"
          shift 2
          ;;
        --executable-name)
          executable_name="$2"
          shift 2
          ;;
        --usage-grep)
          usage_grep="$2"
          shift 2
          ;;
        -h|--help)
          usage
          exit 0
          ;;
        *)
          echo "unknown option: $1" >&2
          usage >&2
          exit 2
          ;;
      esac
    done

    if [ -z "$artifacts_dir" ] \
        || [ -z "$artifact_version" ] \
        || [ -z "$executable_name" ]; then
      usage >&2
      exit 2
    fi

    artifacts_dir="$(cd "$artifacts_dir" && pwd)"
    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' EXIT

    smoke_cli() {
      bin="$1"
      test -x "$bin"
      output="$("$bin" 2>&1 >/dev/null || true)"
      printf '%s\n' "$output"
      grep -F -- "Usage:" <<<"$output" >/dev/null
      if [ -n "$usage_grep" ]; then
        grep -F -- "$usage_grep" <<<"$output" >/dev/null
      fi
    }

    smoke_appimage() {
      appimage="$artifacts_dir/$executable_name-$artifact_version-$system_suffix.AppImage"
      test -f "$appimage"
      appimage_dir="$workdir/appimage"
      mkdir -p "$appimage_dir"
      appimage_copy="$appimage_dir/$executable_name.AppImage"
      cp -L "$appimage" "$appimage_copy"
      chmod +x "$appimage_copy"
      (
        cd "$appimage_dir"
        "$appimage_copy" --appimage-extract >/dev/null
      )
      bin="$(find "$appimage_dir" -name "$executable_name" -type f -executable | head -1)"
      smoke_cli "$bin"
    }

    reject_duplicate_appimage() {
      duplicate="$artifacts_dir/$executable_name.AppImage"
      if [ -e "$duplicate" ]; then
        echo "unexpected duplicate AppImage asset: $duplicate" >&2
        exit 1
      fi
    }

    smoke_deb() {
      deb="$artifacts_dir/$executable_name-$artifact_version-$system_suffix.deb"
      test -f "$deb"
      deb_dir="$workdir/deb"
      mkdir -p "$deb_dir"
      dpkg-deb -x "$deb" "$deb_dir"
      bin="$(find "$deb_dir" -name "$executable_name" -type f -executable | head -1)"
      smoke_cli "$bin"
    }

    smoke_rpm() {
      rpm="$artifacts_dir/$executable_name-$artifact_version-$system_suffix.rpm"
      test -f "$rpm"
      rpm_dir="$workdir/rpm"
      mkdir -p "$rpm_dir"
      (
        cd "$rpm_dir"
        rpm2cpio "$rpm" | cpio -idm >/dev/null
      )
      bin="$(find "$rpm_dir" -name "$executable_name" -type f -executable | head -1)"
      smoke_cli "$bin"
    }

    reject_duplicate_appimage
    smoke_appimage
    smoke_deb
    smoke_rpm
  '';
}
