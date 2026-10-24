//! 正文句内短碎片合并（Fushi `cue_fragment_merger.dart` 搬来，逐条一致）。
//!
//! 重切器只在正文句末加切点，但 ASR 原有的 cue 边界只要落在标点 / 空白间隙上就原样
//! 保留——朗读者在「、」「──」后换气，VAD 就在那里切开。结果是一句话被切成「何か、」
//! 「おかしい。」两条，前一条只亮 0.5 s 就换掉（七魔剣 II 整卷 8143 条里 754 条不足
//! 0.8 s，其中以「、」结尾 259 条、以「──」结尾 76 条；对照 YuiMoe 一句一条，159 条）。
//!
//! 规则：相邻两条都命中正文、同一章、正文区间首尾相接、同一音频文件，前一条在正文里
//! **不是句末**（[is_sentence_end]），且任一侧短于 `short_ms`——合并后不超过 `max_chars`
//! 个 UTF-16 码元、`max_duration_ms` 毫秒、中间停顿不超过 `max_gap_ms`，就并成一条（起点
//! 取前条、终点取后条，文本首尾相接）。可连锁并多段。只并不拆，正文区间并集不变。

use crate::energy::exact_int;

/// 合并参数：`shortMs, maxChars, maxDurationMs, maxGapMs`（都是精确整数）。
pub struct MergeParams {
    /// 任一侧短于此值才并（两侧都够长的句内停顿保持分开，长句照常分屏）。
    pub short_ms: i64,
    /// 合并后的正文码元数上限（含标点）。
    pub max_chars: i64,
    /// 合并后的时长上限。
    pub max_duration_ms: i64,
    /// 两条之间的停顿上限：再长就是朗读者真的停住了，分开显示更贴声音。
    pub max_gap_ms: i64,
}

/// 参数个数。
pub const MERGE_PARAM_COUNT: usize = 4;

impl MergeParams {
    pub(crate) fn from_slice(p: &[f64]) -> Option<Self> {
        Some(Self {
            short_ms: exact_int(p[0])?,
            max_chars: exact_int(p[1])?,
            max_duration_ms: exact_int(p[2])?,
            max_gap_ms: exact_int(p[3])?,
        })
    }
}

/// Dart `String.trimRight` 认的空白码元（VM `_StringBase._isWhitespace`：Unicode
/// White_Space + BOM）。
fn is_dart_whitespace(u: u16) -> bool {
    if u <= 32 {
        return u == 32 || (9..=13).contains(&u);
    }
    if u < 0x85 {
        return false;
    }
    if u == 0x85 || u == 0xA0 {
        return true;
    }
    if u <= 0x200A {
        return u == 0x1680 || u >= 0x2000;
    }
    matches!(u, 0x2028 | 0x2029 | 0x202F | 0x205F | 0x3000 | 0xFEFF)
}

/// 句末字符：句号类、闭引号 / 闭括号。省略号与破折号不算（「だが──」常接下文）。
const TERMINATORS: [u16; 13] = [
    0x3002, // 。
    0xFF01, // ！
    0xFF1F, // ？
    0x21,   // !
    0x3F,   // ?
    0x300D, // 」
    0x300F, // 』
    0xFF09, // ）
    0x29,   // )
    0x3011, // 】
    0x3015, // 〕
    0x3009, // 〉
    0x300B, // 》
];

fn is_latin_letter(c: u16) -> bool {
    (0x41..=0x5A).contains(&c)
        || (0x61..=0x7A).contains(&c)
        || (0xFF21..=0xFF3A).contains(&c)
        || (0xFF41..=0xFF5A).contains(&c)
}

/// 正文 `text`（UTF-16 码元）是否以句末结束。`．` / `.` 紧跟拉丁字母时是缩写
/// （`Ｍｓ．`），不算。空文本（含只有空白）算句末。
pub fn is_sentence_end(text: &[u16]) -> bool {
    let mut len = text.len();
    while len > 0 && is_dart_whitespace(text[len - 1]) {
        len -= 1;
    }
    if len == 0 {
        return true;
    }
    let last = text[len - 1];
    if TERMINATORS.contains(&last) {
        return true;
    }
    if last == 0xFF0E || last == 0x2E {
        if len < 2 {
            return true;
        }
        return !is_latin_letter(text[len - 2]);
    }
    false
}

fn is_spoken(c: u32) -> bool {
    (0x30..=0x39).contains(&c)
        || (0x41..=0x5A).contains(&c)
        || (0x61..=0x7A).contains(&c)
        || ((0x3041..=0x309F).contains(&c) && c != 0x309B && c != 0x309C)
        || (0x30A1..=0x30FA).contains(&c)
        || c == 0x30FC
        || (0x3400..=0x4DBF).contains(&c)
        || (0x4E00..=0x9FFF).contains(&c)
        || (0xF900..=0xFAFF).contains(&c)
        || (0xFF10..=0xFF19).contains(&c)
        || (0xFF21..=0xFF3A).contains(&c)
        || (0xFF41..=0xFF5A).contains(&c)
        || (0xFF66..=0xFF9D).contains(&c)
        || (0x20000..=0x2FFFF).contains(&c)
}

/// 字速分档用的字数：字母、数字（含全角）、假名、汉字；标点与空白不算。按码点数
/// （Dart `String.runes`；落单的代理码元按其码元值算，不在任何区间里）。
pub fn spoken_char_count(text: &[u16]) -> i64 {
    char::decode_utf16(text.iter().copied())
        .filter(|r| match r {
            Ok(c) => is_spoken(*c as u32),
            Err(e) => is_spoken(e.unpaired_surrogate() as u32),
        })
        .count() as i64
}

/// 参与合并判定的一条 cue。
#[derive(Clone, Copy)]
pub struct MergeCue<'a> {
    pub start: i64,
    pub end: i64,
    pub file: i64,
    /// 正文章节序号；< 0 = 未命中正文。
    pub section: i64,
    pub norm_start: i64,
    pub norm_end: i64,
    pub text: &'a [u16],
}

/// 合并后的一组。
pub struct MergedGroup {
    pub start: i64,
    pub end: i64,
    pub file: i64,
    pub section: i64,
    pub norm_end: i64,
    pub text: Vec<u16>,
}

impl MergedGroup {
    fn of(c: &MergeCue) -> Self {
        Self {
            start: c.start,
            end: c.end,
            file: c.file,
            section: c.section,
            norm_end: c.norm_end,
            text: c.text.to_vec(),
        }
    }

    fn can_join(&self, b: &MergeCue, p: &MergeParams) -> bool {
        if self.section < 0 || b.section < 0 {
            return false;
        }
        if self.section != b.section {
            return false;
        }
        if self.norm_end != b.norm_start {
            return false;
        }
        if self.file != b.file {
            return false;
        }
        if is_sentence_end(&self.text) {
            return false;
        }
        let gap = b.start - self.end;
        if gap < 0 || gap > p.max_gap_ms {
            return false;
        }
        if self.end - self.start >= p.short_ms && b.end - b.start >= p.short_ms {
            return false;
        }
        if b.end - self.start > p.max_duration_ms {
            return false;
        }
        (self.text.len() + b.text.len()) as i64 <= p.max_chars
    }

    fn join(&mut self, b: &MergeCue) {
        self.end = b.end;
        self.norm_end = b.norm_end;
        self.text.extend_from_slice(b.text);
    }
}

/// 逐条决定并到哪一组；返回 `(每条所属组号, 各组, 并掉的条数)`。
pub fn plan_merges(cues: &[MergeCue], p: &MergeParams) -> (Vec<i64>, Vec<MergedGroup>, i64) {
    let mut group_of = Vec::with_capacity(cues.len());
    let mut groups: Vec<MergedGroup> = Vec::with_capacity(cues.len());
    let mut merged = 0i64;
    for c in cues {
        if let Some(last) = groups.last_mut() {
            if last.can_join(c, p) {
                last.join(c);
                merged += 1;
                group_of.push(groups.len() as i64 - 1);
                continue;
            }
        }
        groups.push(MergedGroup::of(c));
        group_of.push(groups.len() as i64 - 1);
    }
    (group_of, groups, merged)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    #[test]
    fn sentence_end_rules() {
        assert!(is_sentence_end(&u("おかしい。")));
        assert!(is_sentence_end(&u("「何？」")));
        assert!(is_sentence_end(&u("")));
        assert!(is_sentence_end(&u(" \u{3000}")));
        assert!(is_sentence_end(&u("終わり。\u{3000}")));
        assert!(!is_sentence_end(&u("何か、")));
        assert!(!is_sentence_end(&u("だが──")));
        assert!(!is_sentence_end(&u("それは……")));
        // 缩写：拉丁字母后的句点不算句末。
        assert!(!is_sentence_end(&u("Ｍｓ．")));
        assert!(!is_sentence_end(&u("Mr.")));
        assert!(is_sentence_end(&u("三．")));
        assert!(is_sentence_end(&u(".")));
    }

    #[test]
    fn spoken_chars_skip_punctuation() {
        assert_eq!(spoken_char_count(&u("何か、おかしい。")), 6);
        assert_eq!(spoken_char_count(&u("ＡＢ１２ゝ")), 5);
        assert_eq!(spoken_char_count(&u("゛゜ー")), 1);
        assert_eq!(spoken_char_count(&u("𠮷")), 1);
        assert_eq!(spoken_char_count(&[0xD842]), 0);
    }

    fn p() -> MergeParams {
        MergeParams {
            short_ms: 1200,
            max_chars: 40,
            max_duration_ms: 10000,
            max_gap_ms: 1500,
        }
    }

    fn cue<'a>(start: i64, end: i64, ns: i64, ne: i64, text: &'a [u16]) -> MergeCue<'a> {
        MergeCue {
            start,
            end,
            file: 0,
            section: 0,
            norm_start: ns,
            norm_end: ne,
            text,
        }
    }

    #[test]
    fn merges_chain_and_respects_sentence_end() {
        let (a, b, c, d) = (u("何か、"), u("その、"), u("おかしい。"), u("次。"));
        let cues = [
            cue(0, 500, 0, 3, &a),
            cue(600, 1000, 3, 6, &b),
            cue(1100, 3000, 6, 11, &c),
            cue(3100, 3400, 11, 13, &d),
        ];
        let (group_of, groups, merged) = plan_merges(&cues, &p());
        assert_eq!(group_of, vec![0, 0, 0, 1]);
        assert_eq!(merged, 2);
        assert_eq!((groups[0].start, groups[0].end), (0, 3000));
        assert_eq!(groups[0].text, u("何か、その、おかしい。"));
    }

    #[test]
    fn keeps_apart_when_any_rule_fails() {
        let (a, b) = (u("何か、"), u("おかしい。"));
        let base = [cue(0, 500, 0, 3, &a), cue(700, 2500, 3, 9, &b)];
        assert_eq!(plan_merges(&base, &p()).2, 1);
        let check = |mut cs: [MergeCue; 2]| {
            let f = |c: &mut [MergeCue; 2]| plan_merges(c, &p()).2;
            f(&mut cs)
        };
        // 未命中 / 跨章 / 区间不接 / 跨文件。
        assert_eq!(
            check([
                MergeCue {
                    section: -1,
                    ..base[0]
                },
                base[1]
            ]),
            0
        );
        assert_eq!(
            check([
                base[0],
                MergeCue {
                    section: 1,
                    ..base[1]
                }
            ]),
            0
        );
        assert_eq!(
            check([
                base[0],
                MergeCue {
                    norm_start: 4,
                    ..base[1]
                }
            ]),
            0
        );
        assert_eq!(check([base[0], MergeCue { file: 1, ..base[1] }]), 0);
        // 停顿过长 / 重叠。
        assert_eq!(
            check([
                base[0],
                MergeCue {
                    start: 2100,
                    ..base[1]
                }
            ]),
            0
        );
        assert_eq!(
            check([
                base[0],
                MergeCue {
                    start: 400,
                    ..base[1]
                }
            ]),
            0
        );
        // 两侧都够长。
        assert_eq!(
            check([
                MergeCue {
                    end: 1300,
                    ..base[0]
                },
                MergeCue {
                    start: 1300,
                    ..base[1]
                }
            ]),
            0
        );
        // 超时长 / 超字数。
        assert_eq!(
            check([
                base[0],
                MergeCue {
                    end: 10_100,
                    ..base[1]
                }
            ]),
            0
        );
        let long = u(&"あ".repeat(38));
        assert_eq!(
            check([
                base[0],
                MergeCue {
                    text: &long,
                    ..base[1]
                }
            ]),
            0
        );
    }
}
