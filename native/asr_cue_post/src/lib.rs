//! `fcp_*`：设备端转录产物（有声书逐句 cue）的落库前后处理，整本书一次 FFI 调用。
//!
//! 四步，按顺序（每步可单独关掉，见 [stage]）：
//! 1. [energy::snap_cues]：紧挨着的两条 cue 之间的切点吸到能量谷（真实停顿）上；
//! 2. [energy::refine_edges]：起止点落在静音里时收回到真实有声处；
//! 3. [merge::plan_merges]：正文句内的短碎片并回相邻 cue（只并不拆）；
//! 4. [margins::display_margins]：按语速给跟读显示留余量（只外扩）。
//!
//! 1、2、4 从 Fushi 的 `native/fushi_compute/src/signal.rs` 搬来，3 从 Fushi 的
//! `cue_fragment_merger.dart` 搬来；搬迁前的输出冻结在
//! `packages/asr_subtitles/test/fixtures/cue_post_vectors.json`，逐位一致。
//!
//! Dart 侧（`fushi_asr_subtitles` 的 `AsrCuePostProcessor`）只负责打包与写回：对象构造、
//! token 偏移的平移拼接按这里给出的起止与分组做。

use std::panic::{catch_unwind, AssertUnwindSafe};

mod energy;
mod margins;
mod merge;
mod pipeline;

pub use energy::{SnapParams, SNAP_PARAM_COUNT};
pub use margins::{DisplayParams, DISPLAY_PARAM_COUNT};
pub use merge::{is_sentence_end, spoken_char_count, MergeParams, MERGE_PARAM_COUNT};
pub use pipeline::{post_process, CueIn, PostOutput, PARAM_COUNT};

/// C ABI 版本。改任何导出函数的签名 / 打包布局 / 参数顺序都要 +1，Dart 侧加载时核对。
pub const ABI_VERSION: i32 = 1;

/// 每条 cue 在 i64 数组里占的槽数：
/// `[startMs, endMs, audioFileIndex, hasTokens(0/1), 首 token 偏移, 末 token 偏移,
///   sectionIndex(<0 = 未命中正文), normCharStart, normCharEnd]`。
pub const CUE_STRIDE: usize = 9;

/// 统计槽数：`[分组数, 吸附切点数, 修边边数, 并掉的碎片数, 余量边数]`。
pub const STATS_LEN: usize = 5;

/// 步骤开关位。
pub mod stage {
    pub const SNAP: i32 = 1;
    pub const REFINE_EDGES: i32 = 2;
    pub const MERGE_FRAGMENTS: i32 = 4;
    pub const DISPLAY_MARGINS: i32 = 8;
    pub const ALL: i32 = SNAP | REFINE_EDGES | MERGE_FRAGMENTS | DISPLAY_MARGINS;
}

/// 返回码（与 Fushi `fushi_compute` 同一套取值）。
pub mod status {
    pub const OK: i32 = 0;
    /// 必需的指针为空。
    pub const NULL_ARGUMENT: i32 = -1;
    /// 参数取值非法（长度、取值范围、文本偏移不单调）。
    pub const INVALID_ARGUMENT: i32 = -2;
    /// Rust 侧 panic（已接住）。
    pub const PANIC: i32 = -100;
}

/// 跑 [body]，把 panic 转成 [status::PANIC]。
fn guard(body: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(status::PANIC)
}

/// # Safety
/// `len > 0` 时 `ptr` 至少 `len` 个元素可读。
unsafe fn slice_in<'a, T>(ptr: *const T, len: usize) -> Option<&'a [T]> {
    if len == 0 {
        Some(&[])
    } else if ptr.is_null() {
        None
    } else {
        Some(std::slice::from_raw_parts(ptr, len))
    }
}

/// # Safety
/// `len > 0` 时 `ptr` 至少 `len` 个元素可写。
unsafe fn slice_out<'a, T>(ptr: *mut T, len: usize) -> Option<&'a mut [T]> {
    if len == 0 {
        Some(&mut [])
    } else if ptr.is_null() {
        None
    } else {
        Some(std::slice::from_raw_parts_mut(ptr, len))
    }
}

/// [ABI_VERSION]。
#[no_mangle]
pub extern "C" fn fcp_abi_version() -> i32 {
    ABI_VERSION
}

/// 整本书的转录 cue 后处理，一次调用跑完 [stage] 选中的步骤。
///
/// - `energy`：从时间 0 起每 `frameMs` 一帧的整数 dBFS（0 = 未知，按有声处理）；长度 0 时
///   吸附 / 修边 / 余量三步都跳过（碎片合并照常）。
/// - `cues`：`cue_count` × [CUE_STRIDE] 个 i64，按时间排序。返回时每条的起止与首末 token
///   偏移改写成**吸附 + 修边之后、合并之前**的值（Dart 侧据此平移 token 偏移）。
/// - `text` / `text_offsets`：全部 cue 文本的 UTF-16 码元首尾相接；第 i 条是
///   `text[text_offsets[i] .. text_offsets[i + 1])`，`text_offsets` 有 `cue_count + 1` 项、
///   单调不减、末项 = `text_len`。
/// - `params`：[PARAM_COUNT] 个 f64，依次是吸附（[SNAP_PARAM_COUNT]）、合并
///   （[MERGE_PARAM_COUNT]）、余量（[DISPLAY_PARAM_COUNT]）三组；整数参数必须是精确整数。
/// - `stages`：[stage] 位的组合。
/// - `out_group`：`cue_count` 个 i64，第 i 条所属的输出分组（从 0 起、单调、相邻同组 =
///   并成了一条）。
/// - `out_times`：至少 `2 × cue_count` 个 i64，第 g 组的最终起止写在 `[2g, 2g + 1]`。
/// - `out_stats`：[STATS_LEN] 个 i64，见该常量。
///
/// # Safety
/// 各指针按上面的长度可读 / 可写。
#[no_mangle]
pub unsafe extern "C" fn fcp_cue_post_process(
    energy: *const i8,
    energy_len: usize,
    cues: *mut i64,
    cue_count: usize,
    text: *const u16,
    text_len: usize,
    text_offsets: *const i64,
    params: *const f64,
    stages: i32,
    out_group: *mut i64,
    out_times: *mut i64,
    out_stats: *mut i64,
) -> i32 {
    guard(|| {
        let Some(db) = slice_in(energy, energy_len) else {
            return status::NULL_ARGUMENT;
        };
        let Some(raw) = slice_out(cues, cue_count * CUE_STRIDE) else {
            return status::NULL_ARGUMENT;
        };
        let Some(units) = slice_in(text, text_len) else {
            return status::NULL_ARGUMENT;
        };
        let Some(offsets) = slice_in(text_offsets, cue_count + 1) else {
            return status::NULL_ARGUMENT;
        };
        let Some(param_slice) = slice_in(params, PARAM_COUNT) else {
            return status::NULL_ARGUMENT;
        };
        let Some(groups) = slice_out(out_group, cue_count) else {
            return status::NULL_ARGUMENT;
        };
        let Some(times) = slice_out(out_times, cue_count * 2) else {
            return status::NULL_ARGUMENT;
        };
        if out_stats.is_null() {
            return status::NULL_ARGUMENT;
        }
        let stats = std::slice::from_raw_parts_mut(out_stats, STATS_LEN);
        if stages & !stage::ALL != 0 {
            return status::INVALID_ARGUMENT;
        }
        // 文本偏移：首项 0、单调、末项 = text_len。
        if offsets[0] != 0 || offsets[cue_count] != text_len as i64 {
            return status::INVALID_ARGUMENT;
        }
        if offsets.windows(2).any(|w| w[1] < w[0]) {
            return status::INVALID_ARGUMENT;
        }
        let mut list: Vec<CueIn> = Vec::with_capacity(cue_count);
        for (i, c) in raw.chunks_exact(CUE_STRIDE).enumerate() {
            let a = offsets[i] as usize;
            let b = offsets[i + 1] as usize;
            list.push(CueIn::read(c, &units[a..b]));
        }
        let Some(out) = post_process(&mut list, db, param_slice, stages) else {
            return status::INVALID_ARGUMENT;
        };
        for (cue, slot) in list.iter().zip(raw.chunks_exact_mut(CUE_STRIDE)) {
            cue.write(slot);
        }
        groups.copy_from_slice(&out.group_of);
        for (g, &(s, e)) in out.group_times.iter().enumerate() {
            times[2 * g] = s;
            times[2 * g + 1] = e;
        }
        stats.copy_from_slice(&[
            out.group_times.len() as i64,
            out.snapped,
            out.refined,
            out.merged,
            out.margin_edges,
        ]);
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guard_turns_panic_into_status() {
        assert_eq!(guard(|| panic!("boom")), status::PANIC);
        assert_eq!(guard(|| status::OK), status::OK);
    }

    fn run(
        energy: &[i8],
        cues: &mut [i64],
        texts: &[&str],
        stages: i32,
    ) -> (i32, Vec<i64>, Vec<i64>, [i64; STATS_LEN]) {
        let mut units: Vec<u16> = Vec::new();
        let mut offsets = vec![0i64];
        for t in texts {
            units.extend(t.encode_utf16());
            offsets.push(units.len() as i64);
        }
        let n = cues.len() / CUE_STRIDE;
        let params = pipeline::default_params();
        let mut groups = vec![0i64; n];
        let mut times = vec![0i64; 2 * n];
        let mut stats = [0i64; STATS_LEN];
        let rc = unsafe {
            fcp_cue_post_process(
                energy.as_ptr(),
                energy.len(),
                cues.as_mut_ptr(),
                n,
                units.as_ptr(),
                units.len(),
                offsets.as_ptr(),
                params.as_ptr(),
                stages,
                groups.as_mut_ptr(),
                times.as_mut_ptr(),
                stats.as_mut_ptr(),
            )
        };
        (rc, groups, times, stats)
    }

    #[test]
    fn merges_fragment_and_reports_groups() {
        // 两条命中、同章、区间相接、前条以「、」结尾且只有 0.5 s。
        let mut cues = vec![
            0, 500, 0, 0, 0, 0, 0, 0, 3, //
            700, 2500, 0, 0, 0, 0, 0, 3, 9, //
        ];
        let (rc, groups, times, stats) = run(&[], &mut cues, &["何か、", "おかしい。"], stage::ALL);
        assert_eq!(rc, status::OK);
        assert_eq!(groups, vec![0, 0]);
        assert_eq!(&times[..2], &[0, 2500]);
        assert_eq!(stats, [1, 0, 0, 1, 0]);
    }

    #[test]
    fn rejects_bad_offsets_and_stage_bits() {
        let mut cues = vec![0, 500, 0, 0, 0, 0, -1, -1, -1];
        let mut units = vec![0x61u16];
        let offsets = [0i64, 2]; // 末项 ≠ text_len
        let params = pipeline::default_params();
        let mut groups = [0i64; 1];
        let mut times = [0i64; 2];
        let mut stats = [0i64; STATS_LEN];
        let rc = unsafe {
            fcp_cue_post_process(
                std::ptr::null(),
                0,
                cues.as_mut_ptr(),
                1,
                units.as_mut_ptr(),
                1,
                offsets.as_ptr(),
                params.as_ptr(),
                stage::ALL,
                groups.as_mut_ptr(),
                times.as_mut_ptr(),
                stats.as_mut_ptr(),
            )
        };
        assert_eq!(rc, status::INVALID_ARGUMENT);
        let (rc, ..) = run(&[], &mut cues, &["a"], 16);
        assert_eq!(rc, status::INVALID_ARGUMENT);
    }

    #[test]
    fn abi_version_is_exported() {
        assert_eq!(fcp_abi_version(), ABI_VERSION);
    }
}
