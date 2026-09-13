#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/env.sh"
cd "$ROOT_DIR"

dart pub get
status=0
if ! dart analyze packages; then
  status=1
fi

for package in asr_core asr_onnx_ffi asr_align asr asr_server asr_cli; do
  echo "==> Testing packages/$package"
  if ! (cd "$ROOT_DIR/packages/$package" && dart test); then
    status=1
  fi
done

exit "$status"
