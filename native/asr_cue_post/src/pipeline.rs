//! 四步串起来：吸附 → 修边 → 碎片合并 → 显示余量。

use crate::energy::{refine_edges, snap_cues, SnapCue, SnapParams, SNAP_PARAM_COUNT};
use crate::margins::{display_margins, DisplayCue, DisplayParams, DISPLAY_PARAM_COUNT};
use crate::merge::{plan_merges, spoken_char_count, MergeCue, MergeParams, MERGE_PARAM_COUNT};
use crate::stage;

/// 参数总数：吸附、合并、余量三组首尾相接。
pub const PARAM_COUNT: usize = SNAP_PARAM_COUNT + MERGE_PARAM_COUNT + DISPLAY_PARAM_COUNT;

/// 一条输入 cue（[crate::CUE_STRIDE] 槽 + 文本）。
pub struct CueIn<'a> {
    pub time: SnapCue,
    /// 正文章节序号；< 0 = 未命中正文。
    pub section: i64,
    pub norm_start: i64,
    pub norm_end: i64,
    pub text: &'a [u16],
}

impl<'a> CueIn<'a> {
    pub(crate) fn read(c: &[i64], text: &'a [u16]) -> Self {
        Self {
            time: SnapCue {
                start: c[0],
                end: c[1],
                file: c[2],
                has_tokens: c[3] != 0,
                first: c[4],
                last: c[5],
            },
            section: c[6],
            norm_start: c[7],
            norm_end: c[8],
            text,
        }
    }

    pub(crate) fn write(&self, c: &mut [i64]) {
        c[0] = self.time.start;
        c[1] = self.time.end;
        c[4] = self.time.first;
        c[5] = self.time.last;
    }
}

/// [post_process] 的结果。输入 cue 的起止 / 首末 token 偏移已就地改成吸附 + 修边之后的值。
pub struct PostOutput {
    /// 每条输入 cue 所属的组号。
    pub group_of: Vec<i64>,
    /// 各组最终起止（余量之后）。
    pub group_times: Vec<(i64, i64)>,
    pub snapped: i64,
    pub refined: i64,
    pub merged: i64,
    pub margin_edges: i64,
}

/// 跑 `stages` 选中的步骤；参数非法返回 None（三组参数无论步骤开没开都校验）。
/// `db` 为空时吸附 / 修边 / 余量跳过。
pub fn post_process(
    cues: &mut [CueIn],
    db: &[i8],
    params: &[f64],
    stages: i32,
) -> Option<PostOutput> {
    if params.len() != PARAM_COUNT {
        return None;
    }
    let (snap_p, rest) = params.split_at(SNAP_PARAM_COUNT);
    let (merge_p, display_p) = rest.split_at(MERGE_PARAM_COUNT);
    let snap_p = SnapParams::from_slice(snap_p)?;
    let merge_p = MergeParams::from_slice(merge_p)?;
    let display_p = DisplayParams::from_slice(display_p)?;

    let mut times: Vec<SnapCue> = cues.iter().map(|c| c.time).collect();
    let mut snapped = 0;
    let mut refined = 0;
    if stages & stage::SNAP != 0 {
        snapped = snap_cues(&mut times, db, &snap_p);
    }
    if stages & stage::REFINE_EDGES != 0 {
        refined = refine_edges(&mut times, db, &snap_p);
    }
    for (c, t) in cues.iter_mut().zip(times.iter()) {
        c.time = *t;
    }

    let merge_in: Vec<MergeCue> = cues
        .iter()
        .map(|c| MergeCue {
            start: c.time.start,
            end: c.time.end,
            file: c.time.file,
            section: c.section,
            norm_start: c.norm_start,
            norm_end: c.norm_end,
            text: c.text,
        })
        .collect();
    let disabled = MergeParams {
        short_ms: 0,
        max_chars: -1,
        max_duration_ms: -1,
        max_gap_ms: -1,
    };
    let merge_rules = if stages & stage::MERGE_FRAGMENTS != 0 {
        &merge_p
    } else {
        &disabled
    };
    let (group_of, groups, merged) = plan_merges(&merge_in, merge_rules);

    let mut display: Vec<DisplayCue> = groups
        .iter()
        .map(|g| DisplayCue {
            start: g.start,
            end: g.end,
            file: g.file,
            chars: spoken_char_count(&g.text),
        })
        .collect();
    let mut margin_edges = 0;
    if stages & stage::DISPLAY_MARGINS != 0 {
        margin_edges = display_margins(&mut display, db, &display_p);
    }
    Some(PostOutput {
        group_of,
        group_times: display.iter().map(|d| (d.start, d.end)).collect(),
        snapped,
        refined,
        merged,
        margin_edges,
    })
}

/// 默认参数（与 Dart 侧 `AsrCuePostOptions` 的默认值一致），给本 crate 的测试用。
#[cfg(test)]
pub(crate) fn default_params() -> Vec<f64> {
    vec![
        // 吸附 / 修边
        20.0, 400.0, 600.0, 120.0, 0.5, 80.0, 40.0, 500.0, 16.0, -50.0, -30.0, 1000.0, 600.0, 60.0,
        150.0, 80.0, 350.0, //
        // 合并
        1200.0, 40.0, 10000.0, 1500.0, //
        // 余量
        20.0, 16.0, -50.0, -30.0, 60.0, 5.5, 7.0, 120.0, 80.0, 40.0, 180.0, 100.0, 20.0, 0.18,
        250.0, 400.0, 50.0,
    ]
}
