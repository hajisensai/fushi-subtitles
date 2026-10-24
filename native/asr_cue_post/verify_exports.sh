#!/usr/bin/env bash
# 产物校验：构建出的 fushi_asr_cue_post 原生库（.so / .dylib / 静态库 .a）必须导出 Dart 绑定
# 要 lookup 的**每一个** fcp_* 符号。FFI 的失败形态是「文件在、符号不在」（strip / dead-strip /
# LTO 任何一环不对都会静默去掉），只断言文件存在的构建脚本看不出来。
#
# 期望集取自 packages/asr_subtitles/lib/src/cue_post/ 下所有 .dart 里的 'fcp_xxx' 字面量。
#
# 用法: verify_exports.sh <binary> [nm-binary]
set -euo pipefail

BIN="${1:?usage: verify_exports.sh <binary> [nm-binary]}"
NM="${2:-nm}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINDINGS_DIR="$SCRIPT_DIR/../../packages/asr_subtitles/lib/src/cue_post"

[[ -f "$BIN" ]] || { echo "::error::artifact not found: $BIN" >&2; exit 1; }

expected="$(grep -rhoE --include='*.dart' "'fcp_[a-z0-9_]+'" "$BINDINGS_DIR" | tr -d "'" | sort -u || true)"
count="$(printf '%s\n' "$expected" | grep -c . || true)"
# 哨兵：正则被绑定的格式改写打断时期望集会塌成 0 条，「全都导出了」恒真。
if [[ "$count" -lt 2 ]]; then
  echo "::error::only $count fcp_* names parsed from the Dart bindings (<2); the scan is broken" >&2
  exit 1
fi

# 共享库按动态符号表查（release 产物 strip 过，普通符号表是空的）；静态库查全局符号。
magic="$(head -c 4 "$BIN" | od -An -tx1 | tr -d ' \n')"
case "$BIN" in
  *.a) exported="$("$NM" -g "$BIN")" ;;
  *)
    if [[ "$magic" == "7f454c46" ]]; then
      exported="$("$NM" -D --defined-only "$BIN")"
    else
      exported="$("$NM" -gU "$BIN")"
    fi
    ;;
esac

missing=0
while IFS= read -r sym; do
  # Mach-O 符号带前导下划线。
  if ! grep -qE "[[:space:]]_?${sym}\$" <<<"$exported"; then
    echo "::error::$BIN does not export $sym" >&2
    missing=1
  fi
done <<<"$expected"
[[ "$missing" -eq 0 ]] || exit 1
echo "$BIN exports all $count fcp_* symbols"
