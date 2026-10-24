//! 跟读显示余量（Fushi `fushi_compute` 的 `signal.rs` `display_margins` 原样搬来，逐位一致）。

use crate::energy::{ceil_div_f64, exact_int, thresholds};

/// 余量参数，按 [DISPLAY_PARAM_COUNT] 个 f64 传。
pub struct DisplayParams {
    pub frame_ms: i64,
    pub floor_margin_db: f64,
    pub min_threshold_db: f64,
    pub max_threshold_db: f64,
    pub min_voice_ms: i64,
    pub slow_cps: f64,
    pub fast_cps: f64,
    /// 起点提前量，按档 `[慢, 正常, 快]`。
    pub head_ms: [i64; 3],
    /// 收声后续显的基础量，按档 `[慢, 正常, 快]`。
    pub tail_ms: [i64; 3],
    pub gap_tail_ratio: f64,
    pub tail_cap_ms: i64,
    pub glue_ms: i64,
    pub tail_safety_ms: i64,
}

/// 参数个数：`frameMs, floorMarginDb, minThresholdDb, maxThresholdDb, minVoiceMs,
/// slowCps, fastCps, headSlowMs, headNormalMs, headFastMs, tailSlowMs, tailNormalMs,
/// tailFastMs, gapTailRatio, tailCapMs, glueMs, tailSafetyMs`。
pub const DISPLAY_PARAM_COUNT: usize = 17;

impl DisplayParams {
    pub(crate) fn from_slice(p: &[f64]) -> Option<Self> {
        let int = exact_int;
        let num = |v: f64| -> Option<f64> { v.is_finite().then_some(v) };
        let params = Self {
            frame_ms: int(p[0])?,
            floor_margin_db: num(p[1])?,
            min_threshold_db: num(p[2])?,
            max_threshold_db: num(p[3])?,
            min_voice_ms: int(p[4])?,
            slow_cps: num(p[5])?,
            fast_cps: num(p[6])?,
            head_ms: [int(p[7])?, int(p[8])?, int(p[9])?],
            tail_ms: [int(p[10])?, int(p[11])?, int(p[12])?],
            gap_tail_ratio: num(p[13])?,
            tail_cap_ms: int(p[14])?,
            glue_ms: int(p[15])?,
            tail_safety_ms: int(p[16])?,
        };
        let ok = params.frame_ms > 0
            && params.min_voice_ms >= 0
            && params.min_threshold_db <= params.max_threshold_db
            && params.slow_cps <= params.fast_cps;
        ok.then_some(params)
    }
}

/// 一条 cue 的显示视图。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DisplayCue {
    pub start: i64,
    pub end: i64,
    pub file: i64,
    /// 正文字数（字速分档用，见 [crate::spoken_char_count]）。
    pub chars: i64,
}

/// `[from_ms, to_ms)` 内第一段有声的起点与最后一段有声的终点（毫秒）；一段至少
/// `min_voice` 帧连续有声才算。
fn voice_span(
    voiced: &dyn Fn(i64) -> bool,
    n: i64,
    from_ms: i64,
    to_ms: i64,
    frame_ms: i64,
    min_voice: i64,
) -> Option<(i64, i64)> {
    let f0 = (from_ms / frame_ms).max(0);
    let f1 = (to_ms / frame_ms).min(n);
    let mut onset = None;
    let mut run = 0i64;
    for f in f0..f1 {
        run = if voiced(f) { run + 1 } else { 0 };
        if run >= min_voice {
            onset = Some((f - run + 1) * frame_ms);
            break;
        }
    }
    let onset = onset?;
    run = 0;
    let mut f = f1 - 1;
    while f >= f0 {
        run = if voiced(f) { run + 1 } else { 0 };
        if run >= min_voice {
            return Some((onset, (f + run) * frame_ms));
        }
        f -= 1;
    }
    None
}

/// 跟读显示余量：按 cue 有声跨度的字速分慢 / 正常 / 快三档，起点在开口前、终点在
/// 收声后各留一段（快档几乎不留，慢档前后一两百毫秒），句间停顿越长尾巴越宽
/// （`gapTailRatio × (停顿 − glue)`，封顶 `tailCapMs`；快档不吃这一项）。
///
/// - 只外扩、不内收：吸附 / 修边给出的边界已经贴声音，这里只决定要不要多留；
/// - 与前一条的空地 ≤ `glueMs`（连读 / 窄缝）不提前起点，与后一条停顿 ≤ `glueMs` 不延尾；
/// - 起点不早于前一条（已处理后的）终点 + 1 ms，终点不晚于后一条起点 − `tailSafetyMs`；
///   跨音频文件的邻居不参与；
/// - 没有有声帧（全静音）或没有正文字数的 cue 不动。
///
/// 返回动过的边数。
pub fn display_margins(cues: &mut [DisplayCue], db: &[i8], p: &DisplayParams) -> i64 {
    let n = db.len() as i64;
    let count = cues.len();
    if n == 0 || count == 0 {
        return 0;
    }
    let threshold = thresholds(
        db,
        p.floor_margin_db,
        p.min_threshold_db,
        p.max_threshold_db,
    );
    let voiced = |f: i64| -> bool {
        let v = db[f as usize];
        v == 0 || (v as f64) >= threshold[f as usize]
    };
    let min_voice = ceil_div_f64(p.min_voice_ms.max(1), p.frame_ms);
    let orig_starts: Vec<i64> = cues.iter().map(|c| c.start).collect();
    let mut moved = 0i64;
    for i in 0..count {
        let DisplayCue {
            start,
            end,
            file,
            chars,
        } = cues[i];
        let Some((on, off)) = voice_span(&voiced, n, start, end, p.frame_ms, min_voice) else {
            continue;
        };
        if off <= on || chars <= 0 {
            continue;
        }
        let cps = chars as f64 / ((off - on) as f64 / 1000.0);
        let tier = if cps >= p.fast_cps {
            2
        } else if cps >= p.slow_cps {
            1
        } else {
            0
        };
        let prev_end = (i > 0 && cues[i - 1].file == file).then(|| cues[i - 1].end);
        let room = prev_end.map_or(i64::MAX, |e| on - e);
        if room > p.glue_ms {
            let floor = prev_end.map_or(0, |e| e + 1);
            let s = start.min((on - p.head_ms[tier]).max(floor));
            if s < start {
                cues[i].start = s;
                moved += 1;
            }
        }
        let next_start = (i + 1 < count && cues[i + 1].file == file).then(|| orig_starts[i + 1]);
        let gap = next_start.map_or(i64::MAX, |s| s - off);
        if gap > p.glue_ms {
            let tail = if tier == 2 {
                p.tail_ms[2]
            } else {
                let by_gap = match next_start {
                    None => p.tail_cap_ms as f64,
                    Some(_) => p.gap_tail_ratio * (gap - p.glue_ms) as f64,
                };
                (p.tail_ms[tier] as f64)
                    .max(by_gap)
                    .min(p.tail_cap_ms as f64)
                    .round() as i64
            };
            let ceiling = next_start.map_or(i64::MAX, |s| s - p.tail_safety_ms);
            let e = end.max((off + tail).min(ceiling));
            if e > end {
                cues[i].end = e;
                moved += 1;
            }
        }
    }
    moved
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::energy::tests::energy;

    fn params() -> DisplayParams {
        DisplayParams::from_slice(&[
            20.0, 16.0, -50.0, -30.0, 60.0, 5.5, 7.0, 120.0, 80.0, 40.0, 180.0, 100.0, 20.0, 0.18,
            250.0, 400.0, 50.0,
        ])
        .unwrap()
    }

    fn cues(raw: &[i64]) -> Vec<DisplayCue> {
        raw.chunks_exact(4)
            .map(|c| DisplayCue {
                start: c[0],
                end: c[1],
                file: c[2],
                chars: c[3],
            })
            .collect()
    }

    fn flat(c: &[DisplayCue]) -> Vec<i64> {
        c.iter().flat_map(|c| [c.start, c.end]).collect()
    }

    #[test]
    fn display_margins_by_tempo() {
        // 有声 [1000, 3000) 与 [5000, 7000)，其余静音。
        let e = energy(9000, &[(0, 1000), (3000, 5000), (7000, 9000)]);
        // 慢：10 字 / 2 s = 5 cps → 头 120；尾 max(180, 0.18 × (2000 − 400) = 288) 封顶 250。
        let mut slow = cues(&[1000, 3080, 0, 10, 5000, 7080, 0, 10]);
        assert_eq!(display_margins(&mut slow, &e, &params()), 4);
        // 第二条后面没有邻居：尾按封顶 250。
        assert_eq!(flat(&slow), vec![880, 3250, 4880, 7250]);
        // 快：20 字 / 2 s = 10 cps → 头 40、尾 20（只外扩：原终点 3080 更晚，不动）。
        let mut fast = cues(&[1000, 3080, 0, 20, 5000, 7080, 0, 20]);
        display_margins(&mut fast, &e, &params());
        assert_eq!(flat(&fast)[..2], [960, 3080]);
        // 连读：停顿只有 300 ms → 前条不延尾、后条不提前。
        let e = energy(9000, &[(0, 1000), (3000, 3300), (5300, 9000)]);
        let mut glued = cues(&[1000, 3000, 0, 10, 3300, 5300, 0, 10]);
        display_margins(&mut glued, &e, &params());
        assert_eq!(glued[0].end, 3000);
        assert_eq!(glued[1].start, 3300);
    }

    #[test]
    fn display_margins_never_cross_neighbours_or_files() {
        let e = energy(9000, &[(0, 1000), (3000, 3600), (5600, 9000)]);
        // 停顿 500 ms：尾 180，且不越过下一条起点 − 50；后条提前也不压前条新终点。
        let mut c = cues(&[1000, 3000, 0, 10, 3500, 5600, 0, 10]);
        display_margins(&mut c, &e, &params());
        assert_eq!(c[0].end, 3180);
        assert_eq!(c[1].start, 3480);
        // 不同文件的邻居不参与：尾按「后面没人」封顶。
        let mut cross = cues(&[1000, 3000, 0, 10, 3500, 5600, 1, 10]);
        display_margins(&mut cross, &e, &params());
        assert_eq!(cross[0].end, 3250);
    }

    #[test]
    fn display_margins_rejects_bad_params() {
        let mut p = vec![
            20.0, 16.0, -50.0, -30.0, 60.0, 5.5, 7.0, 120.0, 80.0, 40.0, 180.0, 100.0, 20.0, 0.18,
            250.0, 400.0, 50.0,
        ];
        p[5] = 8.0; // slowCps > fastCps
        assert!(DisplayParams::from_slice(&p).is_none());
    }
}
