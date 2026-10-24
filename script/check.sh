#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/env.sh"
cd "$ROOT_DIR"

dart pub get
status=0

# fushi_asr_subtitles 的转录 cue 后处理是 Rust（native/asr_cue_post），原生库是硬依赖：
# 先编出 release 产物，asr_subtitles 的测试在仓库里找 target/release/ 下的库。
echo "==> native/asr_cue_post: cargo test + release build"
if ! (cd "$ROOT_DIR/native/asr_cue_post" && cargo test --quiet && cargo build --release --quiet); then
  status=1
fi
if ! dart analyze packages; then
  status=1
fi

for package in asr_core asr_onnx_ffi asr_align asr_subtitles asr asr_server asr_cli; do
  echo "==> Testing packages/$package"
  if ! (cd "$ROOT_DIR/packages/$package" && dart test); then
    status=1
  fi
done

exit "$status"
