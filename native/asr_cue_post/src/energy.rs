//! 能量吸附与修边（Fushi `fushi_compute` 的 `signal.rs` 原样搬来，逐位一致）。
//!
//! 输入是转录时顺手写下的能量包络：从时间 0 起每 `frame_ms` 一帧的整数 dBFS，
//! 0 = 未知（按有声处理）。门限按 250 帧一块、取前后 750 帧已知电平的第 10 百分位当
//! 底噪 + `floor_margin_db`，夹到 `[min_threshold_db, max_threshold_db]`。

use std::cmp::Ordering;

/// Dart `double.compareTo`：−0.0 < 0.0；NaN 与 NaN 相等、比任何非 NaN 都大。
fn dart_compare(a: f64, b: f64) -> Ordering {
    match (a.is_nan(), b.is_nan()) {
        (true, true) => Ordering::Equal,
        (true, false) => Ordering::Greater,
        (false, true) => Ordering::Less,
        (false, false) => {
            if a < b {
                Ordering::Less
            } else if a > b {
                Ordering::Greater
            } else if a == 0.0 {
                // ±0：负零在前。
                match (a.is_sign_negative(), b.is_sign_negative()) {
                    (true, false) => Ordering::Less,
                    (false, true) => Ordering::Greater,
                    _ => Ordering::Equal,
                }
            } else {
                Ordering::Equal
            }
        }
    }
}

/// Dart `double.clamp(lo, hi)`（调用方保证 `lo <= hi` 且都不是 NaN）：
/// `this < lo` → lo；`this > hi` → hi（NaN 比 hi 大，所以 NaN → hi）；否则原值。
fn dart_clamp(v: f64, lo: f64, hi: f64) -> f64 {
    if dart_compare(v, lo) == Ordering::Less {
        lo
    } else if dart_compare(v, hi) == Ordering::Greater {
        hi
    } else {
        v
    }
}

/// 精确整数参数（f64 传入）；非整数 / 非有限 / 过大返回 None。
pub(crate) fn exact_int(v: f64) -> Option<i64> {
    (v.is_finite() && v.fract() == 0.0 && v.abs() < 9.0e15).then_some(v as i64)
}

/// 吸附 / 修边参数，按 [SNAP_PARAM_COUNT] 个 f64 传（整数参数是精确整数）。
pub struct SnapParams {
    pub frame_ms: i64,
    pub max_gap_ms: i64,
    pub window_ms: i64,
    pub min_valley_ms: i64,
    pub distance_penalty: f64,
    pub tail_ms: i64,
    pub lead_ms: i64,
    pub min_duration_ms: i64,
    pub floor_margin_db: f64,
    pub min_threshold_db: f64,
    pub max_threshold_db: f64,
    pub token_guard_ms: i64,
    pub edge_max_shift_ms: i64,
    pub edge_min_voice_ms: i64,
    pub edge_lead_ms: i64,
    pub edge_tail_ms: i64,
    /// 切点的已知偏差补偿：选谷时以「token 推算的切点 + 此值」为中心（RNN-T 发射
    /// 系统性偏早，切点跟着偏早）。
    pub cut_bias_ms: i64,
}

/// 参数个数。顺序即 [SnapParams] 的字段顺序。
pub const SNAP_PARAM_COUNT: usize = 17;

impl SnapParams {
    pub(crate) fn from_slice(p: &[f64]) -> Option<Self> {
        let int = exact_int;
        let params = Self {
            frame_ms: int(p[0])?,
            max_gap_ms: int(p[1])?,
            window_ms: int(p[2])?,
            min_valley_ms: int(p[3])?,
            distance_penalty: p[4],
            tail_ms: int(p[5])?,
            lead_ms: int(p[6])?,
            min_duration_ms: int(p[7])?,
            floor_margin_db: p[8],
            min_threshold_db: p[9],
            max_threshold_db: p[10],
            token_guard_ms: int(p[11])?,
            edge_max_shift_ms: int(p[12])?,
            edge_min_voice_ms: int(p[13])?,
            edge_lead_ms: int(p[14])?,
            edge_tail_ms: int(p[15])?,
            cut_bias_ms: int(p[16])?,
        };
        // 原 Dart：`~/ frameMs` 遇 0 抛异常；clamp 的上下限反了抛 ArgumentError。
        let ok = params.frame_ms > 0
            && !params.min_threshold_db.is_nan()
            && !params.max_threshold_db.is_nan()
            && params.min_threshold_db <= params.max_threshold_db;
        ok.then_some(params)
    }
}

/// 一条 cue 的时间视图。token 偏移只需要首 / 末两个（平移规则 `max(0, o - delta)` 单调，
/// 首末位置不变）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SnapCue {
    pub start: i64,
    pub end: i64,
    pub file: i64,
    pub has_tokens: bool,
    pub first: i64,
    pub last: i64,
}

impl SnapCue {
    fn first_token_ms(&self) -> Option<i64> {
        self.has_tokens.then_some(self.start + self.first)
    }

    fn last_token_ms(&self) -> Option<i64> {
        self.has_tokens.then_some(self.start + self.last)
    }

    /// 挪起点时 token 偏移一起平移（夹到 ≥ 0），绝对发射时刻不变。
    fn shift_start(&mut self, start: i64) {
        let delta = start - self.start;
        self.start = start;
        if !self.has_tokens || delta == 0 {
            return;
        }
        self.first = (self.first - delta).max(0);
        self.last = (self.last - delta).max(0);
    }
}

const FLOOR_BLOCK_FRAMES: usize = 250;
const FLOOR_SPAN_FRAMES: usize = 750;

/// 每帧门限：按 250 帧一块，取前后 750 帧内已知电平的第 10 百分位 + margin，夹到上下限。
pub(crate) fn thresholds(db: &[i8], floor_margin_db: f64, min_db: f64, max_db: f64) -> Vec<f64> {
    let n = db.len();
    let mut out = vec![0.0f64; n];
    let mut b0 = 0usize;
    while b0 < n {
        let lo = b0.saturating_sub(FLOOR_SPAN_FRAMES);
        let hi = n.min(b0 + FLOOR_BLOCK_FRAMES + FLOOR_SPAN_FRAMES);
        // 计数排序取第 k 小（与 Dart 的 sort + 下标同值）。
        let mut hist = [0usize; 256];
        let mut count = 0usize;
        for &v in &db[lo..hi] {
            if v != 0 {
                hist[(v as i16 + 128) as usize] += 1;
                count += 1;
            }
        }
        let mut t = max_db;
        if count > 0 {
            // Dart：`((len - 1) * 10 / 100).round()`——先整数乘，再浮点除。
            let k = (((count - 1) * 10) as f64 / 100.0).round() as usize;
            let mut seen = 0usize;
            let mut floor = 0i16;
            for (bucket, &c) in hist.iter().enumerate() {
                seen += c;
                if seen > k {
                    floor = bucket as i16 - 128;
                    break;
                }
            }
            t = dart_clamp(floor as f64 + floor_margin_db, min_db, max_db);
        }
        let end = n.min(b0 + FLOOR_BLOCK_FRAMES);
        out[b0..end].iter_mut().for_each(|x| *x = t);
        b0 += FLOOR_BLOCK_FRAMES;
    }
    out
}

/// Dart `(a / b).ceil()`（int / int → double → ceil）。
pub(crate) fn ceil_div_f64(a: i64, b: i64) -> i64 {
    (a as f64 / b as f64).ceil() as i64
}

/// 把紧挨着的两条 cue 之间的切点吸到能量谷上，返回挪动的切点数。每条 cue 的起点最多
/// 被挪一次（作为「后句」时）。
pub fn snap_cues(cues: &mut [SnapCue], db: &[i8], p: &SnapParams) -> i64 {
    let n = db.len() as i64;
    if n == 0 || cues.len() < 2 {
        return 0;
    }
    let threshold = thresholds(
        db,
        p.floor_margin_db,
        p.min_threshold_db,
        p.max_threshold_db,
    );
    let quiet = |f: i64| -> bool {
        let v = db[f as usize];
        v != 0 && (v as f64) < threshold[f as usize]
    };
    let min_valley = ceil_div_f64(p.min_valley_ms, p.frame_ms);
    let mut moved = 0i64;
    for i in 0..cues.len() - 1 {
        let cur = cues[i];
        let mut next = cues[i + 1];
        if cur.file != next.file {
            continue;
        }
        let gap = next.start - cur.end;
        if gap < 0 || gap > p.max_gap_ms {
            continue;
        }
        let b = (cur.end + next.start) / 2 + p.cut_bias_ms;
        let f0 = ((b - p.window_ms) / p.frame_ms).max(0);
        let f1 = ((b + p.window_ms) / p.frame_ms).min(n);
        let mut best: i64 = -1;
        let mut best_len: i64 = 0;
        let mut best_score: f64 = 0.0;
        let mut f = f0;
        while f < f1 {
            if !quiet(f) {
                f += 1;
                continue;
            }
            let mut s = f;
            while s > 0 && quiet(s - 1) {
                s -= 1;
            }
            while f < n && quiet(f) {
                f += 1;
            }
            let len = f - s;
            if len < min_valley {
                continue;
            }
            let center = ((s + f) * p.frame_ms) as f64 / 2.0;
            let score = (len * p.frame_ms) as f64 - p.distance_penalty * (center - b as f64).abs();
            if best < 0 || score > best_score {
                best = s;
                best_len = len;
                best_score = score;
            }
        }
        if best < 0 {
            continue;
        }
        let valley_start = best * p.frame_ms;
        let valley_end = (best + best_len) * p.frame_ms;
        let end = (valley_start + p.tail_ms).min(valley_end);
        let start = (valley_end - p.lead_ms).max(valley_start).max(end);
        if end - cur.start < p.min_duration_ms || next.end - start < p.min_duration_ms {
            continue;
        }
        if let Some(first) = next.first_token_ms() {
            if start > first + p.token_guard_ms {
                continue;
            }
        }
        next.shift_start(start);
        cues[i + 1] = next;
        cues[i].end = end;
        moved += 1;
    }
    moved
}

/// 起止点落在静音里时收回到真实有声处，返回挪动的边数。只往 cue 内部收。
pub fn refine_edges(cues: &mut [SnapCue], db: &[i8], p: &SnapParams) -> i64 {
    let n = db.len() as i64;
    if n == 0 || cues.is_empty() {
        return 0;
    }
    let threshold = thresholds(
        db,
        p.floor_margin_db,
        p.min_threshold_db,
        p.max_threshold_db,
    );
    let quiet = |f: i64| -> bool {
        let v = db[f as usize];
        v != 0 && (v as f64) < threshold[f as usize]
    };
    let max_shift = p.edge_max_shift_ms / p.frame_ms;
    let min_voice = ceil_div_f64(p.edge_min_voice_ms, p.frame_ms);
    let mut moved = 0i64;
    for cue in cues.iter_mut() {
        let fs = cue.start / p.frame_ms;
        if fs >= 0 && fs < n && quiet(fs) {
            let mut f = fs;
            let limit = n.min(fs + max_shift);
            let mut onset: i64 = -1;
            while f < limit {
                if quiet(f) {
                    f += 1;
                    continue;
                }
                let mut g = f;
                while g < n && !quiet(g) && g - f < min_voice {
                    g += 1;
                }
                if g - f >= min_voice {
                    onset = f;
                    break;
                }
                f = g;
            }
            if onset >= 0 {
                let start = cue.start.max(onset * p.frame_ms - p.edge_lead_ms);
                if start > cue.start && cue.end - start >= p.min_duration_ms {
                    cue.shift_start(start);
                    moved += 1;
                }
            }
        }
        let fe = (cue.end - 1) / p.frame_ms;
        if fe >= 0 && fe < n && quiet(fe) {
            let mut f = fe;
            let limit = (-1i64).max(fe - max_shift);
            let mut offset: i64 = -1;
            while f > limit {
                if quiet(f) {
                    f -= 1;
                    continue;
                }
                let mut g = f;
                while g >= 0 && !quiet(g) && f - g < min_voice {
                    g -= 1;
                }
                if f - g >= min_voice {
                    offset = f;
                    break;
                }
                f = g;
            }
            if offset >= 0 {
                let end = cue.end.min((offset + 1) * p.frame_ms + p.edge_tail_ms);
                let last_ok = match cue.last_token_ms() {
                    None => true,
                    Some(last) => end >= last - p.token_guard_ms,
                };
                if end < cue.end && end - cue.start >= p.min_duration_ms && last_ok {
                    cue.end = end;
                    moved += 1;
                }
            }
        }
    }
    moved
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    #[test]
    fn dart_clamp_and_compare_semantics() {
        assert_eq!(dart_clamp(f64::NAN, 0.0, 1.0), 1.0);
        assert!(dart_clamp(-0.0, 0.0, 1.0).is_sign_positive());
        assert_eq!(dart_clamp(0.5, 0.0, 1.0), 0.5);
        assert_eq!(dart_compare(f64::NAN, f64::INFINITY), Ordering::Greater);
        assert_eq!(dart_compare(-0.0, 0.0), Ordering::Less);
    }

    pub(crate) fn params(cut_bias_ms: f64) -> SnapParams {
        SnapParams::from_slice(&[
            20.0,
            400.0,
            600.0,
            120.0,
            0.5,
            80.0,
            40.0,
            500.0,
            16.0,
            -50.0,
            -30.0,
            200.0,
            600.0,
            60.0,
            150.0,
            80.0,
            cut_bias_ms,
        ])
        .unwrap()
    }

    pub(crate) fn energy(total_ms: usize, silences: &[(usize, usize)]) -> Vec<i8> {
        let mut e = vec![-20i8; total_ms / 20];
        for &(a, b) in silences {
            e[a / 20..b / 20].iter_mut().for_each(|v| *v = -70);
        }
        e
    }

    fn cue(start: i64, end: i64) -> SnapCue {
        SnapCue {
            start,
            end,
            file: 0,
            has_tokens: false,
            first: 0,
            last: 0,
        }
    }

    #[test]
    fn snap_moves_boundary_into_valley() {
        let e = energy(6000, &[(2300, 2700)]);
        let mut cues = [cue(0, 2000), cue(2000, 5000)];
        assert_eq!(snap_cues(&mut cues, &e, &params(0.0)), 1);
        assert_eq!(cues[0].end, 2380);
        assert_eq!(cues[1].start, 2660);
    }

    #[test]
    fn snap_skips_cross_file_and_wide_gaps() {
        let e = energy(6000, &[(2300, 2700)]);
        let mut cross = [
            cue(0, 2000),
            SnapCue {
                file: 1,
                ..cue(2000, 5000)
            },
        ];
        assert_eq!(snap_cues(&mut cross, &e, &params(0.0)), 0);
        let mut wide = [cue(0, 2000), cue(2500, 5000)];
        assert_eq!(snap_cues(&mut wide, &e, &params(0.0)), 0);
    }

    #[test]
    fn snap_shift_clamps_token_offsets_at_zero() {
        let e = energy(6000, &[(2300, 2700)]);
        let mut cues = [
            cue(0, 2000),
            SnapCue {
                has_tokens: true,
                first: 600,
                last: 900,
                ..cue(2000, 5000)
            },
        ];
        assert_eq!(snap_cues(&mut cues, &e, &params(0.0)), 1);
        assert_eq!((cues[1].first, cues[1].last), (0, 240));
        // 新起点晚于首 token + tokenGuardMs（2100 + 200）：吸错了谷，不动。
        let mut guarded = [
            cue(0, 2000),
            SnapCue {
                has_tokens: true,
                first: 100,
                last: 900,
                ..cue(2000, 5000)
            },
        ];
        assert_eq!(snap_cues(&mut guarded, &e, &params(0.0)), 0);
    }

    #[test]
    fn refine_pulls_edges_out_of_silence() {
        let e = energy(6000, &[(0, 1000), (4000, 6000)]);
        let mut cues = [cue(500, 4500)];
        assert_eq!(refine_edges(&mut cues, &e, &params(0.0)), 2);
        assert_eq!(cues[0].start, 850);
        assert_eq!(cues[0].end, 4080);
    }

    #[test]
    fn rejects_bad_params() {
        let mut p = vec![
            20.0, 400.0, 600.0, 120.0, 0.5, 80.0, 40.0, 500.0, 16.0, -50.0, -30.0, 200.0, 600.0,
            60.0, 150.0, 80.0, 0.0,
        ];
        p[0] = 0.0;
        assert!(SnapParams::from_slice(&p).is_none());
        p[0] = 20.0;
        p[9] = -10.0; // min > max
        assert!(SnapParams::from_slice(&p).is_none());
        p[9] = -50.0;
        p[1] = 400.5; // 非整数
        assert!(SnapParams::from_slice(&p).is_none());
    }
}
