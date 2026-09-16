#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="$(nproc)"
FORCE="false"

system_tsmuxer() {
  command -v tsMuxeR 2>/dev/null || true
}

system_vapoursynth() {
  local vspipe_path
  vspipe_path="$(command -v vspipe 2>/dev/null || true)"
  if [[ -n "$vspipe_path" ]] && ldconfig -p 2>/dev/null | grep -q 'libvapoursynth\.so'; then
    echo "$vspipe_path"
  fi
}

build_vapoursynth() {
  local sys; sys="$(system_vapoursynth)"
  if [[ -n "$sys" && "$FORCE" != "true" ]]; then
    echo "System VapourSynth found (vspipe at $sys) - skipping source build. Use --force to build the pinned R65 copy anyway."
    echo "Note: this project pinned R65 specifically for API V4 without VapourSynth's newer Python>=3.12 build requirement - if the system package predates R63 (API V4), mvc-source will fail to load against it."
    return
  fi
  cd "$SCRIPT_DIR/vapoursynth"
  [[ -x ./configure ]] || ./autogen.sh
  [[ -f Makefile ]] || ./configure
  make -j"$JOBS"
}

build_tsmuxer() {
  local sys; sys="$(system_tsmuxer)"
  if [[ -n "$sys" && "$FORCE" != "true" ]]; then
    echo "System tsMuxeR found at $sys - skipping source build. Use --force to build anyway."
    return
  fi
  cd "$SCRIPT_DIR/tsMuxer"
  ./scripts/rebuild_linux.sh
}

build_mvc_source() {
  cd "$SCRIPT_DIR/mvc-source"
  make libvsmvc.so EDGE264_SRC="$SCRIPT_DIR/edge264-mvc" EDGE264_MAKE="CFLAGS=-fPIC" -j"$JOBS"
}

usage() {
  echo "Usage: $0 [--force] [vapoursynth] [tsmuxer] [mvc-source]"
  echo "No target arguments builds all three, in dependency order."
  echo "--force builds from source even if a usable system install is found."
}

main() {
  local targets=()
  local a
  for a in "$@"; do
    case "$a" in
      --force) FORCE="true" ;;
      -h|--help) usage; exit 0 ;;
      *) targets+=("$a") ;;
    esac
  done
  if [[ ${#targets[@]} -eq 0 ]]; then targets=(vapoursynth tsmuxer mvc-source); fi

  local t
  for t in "${targets[@]}"; do
    echo "== Building $t =="
    case "$t" in
      vapoursynth) build_vapoursynth ;;
      tsmuxer) build_tsmuxer ;;
      mvc-source) build_mvc_source ;;
      *) echo "Unknown target: $t" >&2; usage; exit 1 ;;
    esac
  done

  echo "Done."
}

main "$@"
