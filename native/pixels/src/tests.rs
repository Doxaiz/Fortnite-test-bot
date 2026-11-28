use super::*;
use std::mem::{offset_of, size_of};
use std::ptr::null;

const YELLOW_LIMITS: [i32; 4] = [155, 155, 100, 48];
const CREAM_LIMITS: [i32; 3] = [200, 150, 215];

fn mask_query(rect: Rect, modes: u32) -> MaskQuery {
    MaskQuery { rect, cell: 4, step: 1, min_cells: 1, modes, yellow: YELLOW_LIMITS, cream: CREAM_LIMITS }
}

fn pixel(data: &mut [u8], stride: usize, x: usize, y: usize, rgb: [u8; 3]) {
    let i = y * stride + x * 4;
    data[i..i + 4].copy_from_slice(&[rgb[2], rgb[1], rgb[0], 0xA3]);
}

#[test]
fn abi_layout_matches_ahk() {
    assert_eq!(forma_pixels_abi(), 1);
    assert_eq!(size_of::<MaskQuery>(), 60);
    assert_eq!(offset_of!(MaskQuery, yellow), 32);
    assert_eq!(offset_of!(MaskQuery, cream), 48);
    assert_eq!(size_of::<Cluster>(), 36);
    assert_eq!(offset_of!(Cluster, cx), 24);
    assert_eq!(size_of::<PlateQuery>(), 44);
    assert_eq!(offset_of!(PlateQuery, yellow), 28);
    assert_eq!(size_of::<RowRun>(), 8);
    assert_eq!(size_of::<RatioQuery>(), 24);
}

#[test]
fn mask_priority_and_inclusive_thresholds() {
    let mut q = mask_query(Rect::default(), (1 << MODES) - 1);
    for (r, g, b, mode) in [
        (150, 85, 62, CHEST_GOLD), (98, 160, 218, CHEST_RARE), (140, 80, 50, GOLD),
        (80, 120, 80, GREEN), (85, 120, 140, BLUE), (105, 70, 145, PURPLE),
        (110, 65, 65, RED), (245, 245, 238, WHITE), (155, 155, 100, YELLOW),
    ] {
        assert_eq!(color(r, g, b, &q), Some(mode));
    }
    assert_eq!(color(200, 190, 150, &q), None, "gold suppresses cream even when it misses");
    q.modes &= !(1 << GOLD);
    assert_eq!(color(200, 190, 150, &q), Some(CREAM));
    assert_eq!(color(200, 189, 150, &q), None);
    q.modes = 1 << PURE;
    assert_eq!(color(245, 245, 238, &q), Some(PURE));
    assert_eq!(color(245, 245, 237, &q), None);
}

#[test]
fn clusters_use_eight_neighbors_row_order_and_rounded_centers() {
    let (w, h, stride) = (17, 15, 73);
    let mut data = vec![0; stride * h];
    for (x, y) in [(3, 3), (4, 4), (13, 3), (3, 13)] {
        pixel(&mut data, stride, x, y, [235; 3]);
    }
    let mut q = mask_query(Rect { x1: 1, y1: 1, x2: 16, y2: 14 }, 1 << WHITE);
    // Bounds are aligned to full-frame cells, not to the offset ROI.
    let mut out = [Cluster::default(); 3];
    let scan = |q: &MaskQuery, out: &mut [Cluster]| unsafe {
        forma_pixels_clusters(data.as_ptr(), data.len(), w as u32, h as u32, stride, q, out.as_mut_ptr(), out.len())
    };
    assert_eq!(scan(&q, &mut out), 3);
    assert_eq!(out[0], Cluster { mode: WHITE as u32, x: 0, y: 0, w: 8, h: 8, n: 2, cx: 4, cy: 4, cells: 2 });
    assert_eq!((out[1].x, out[1].y, out[2].x, out[2].y), (12, 0, 0, 12));
    assert_eq!(scan(&q, &mut out[..1]), CAPACITY);
    q.min_cells = 2;
    assert_eq!(scan(&q, &mut out), 1);
}

#[test]
fn longest_row_runs_keep_first_tie_and_sample_origin() {
    let (w, h, stride) = (21, 9, 89);
    let mut data = vec![0; stride * h];
    for x in [1, 4, 7, 13, 16, 19] {
        pixel(&mut data, stride, x, 2, [203, 203, 0]);
    }
    for (y, rgb) in [(4, [188, 188, 224]), (6, [150, 158, 222]), (8, [174, 82, 92])] {
        for x in [1, 4, 7, 10] {
            pixel(&mut data, stride, x, y, rgb);
        }
    }
    let mut out = [RowRun::default(); 4];
    let scan = |mode, out: &mut [RowRun]| unsafe {
        let q = PlateQuery { rect: Rect { x1: 1, y1: 2, x2: 20, y2: 9 }, step_x: 3, step_y: 2, mode, yellow: YELLOW_LIMITS };
        forma_pixels_rows(data.as_ptr(), data.len(), w, h as u32, stride, &q, out.as_mut_ptr(), out.len())
    };
    assert_eq!(scan(0, &mut out), 4);
    assert_eq!(out, [RowRun { run: 9, cx: 5 }, RowRun::default(), RowRun::default(), RowRun::default()]);
    assert_eq!(scan(1, &mut out), 4);
    assert_eq!(out[1], RowRun { run: 12, cx: 7 });
    assert_eq!(out[2].run, 0);
    assert_eq!(scan(2, &mut out), 4);
    assert_eq!(out[2], RowRun { run: 12, cx: 7 });
    assert_eq!(scan(3, &mut out), 4);
    assert_eq!(out[3], RowRun { run: 12, cx: 7 });
    assert_eq!(scan(3, &mut out[..3]), CAPACITY);
    assert_eq!(scan(4, &mut out), INVALID);
}

#[test]
fn ratios_ignore_x_and_padding_and_keep_strict_dark_boundary() {
    let (w, h, stride) = (13, 5, 57);
    let mut data = vec![0xFF; stride * h];
    for (x, rgb) in [(1, [39, 40, 40]), (5, [40, 40, 40]), (9, [164, 165, 166])] {
        pixel(&mut data, stride, x, 1, rgb);
    }
    let scan = |mode, threshold| unsafe {
        let q = RatioQuery { rect: Rect { x1: 1, y1: 1, x2: 13, y2: 5 }, mode, threshold };
        forma_pixels_ratio_hits(data.as_ptr(), data.len(), w, h as u32, stride, &q)
    };
    assert_eq!(scan(1, 0), 1);
    assert_eq!(scan(0, 164), 1); // 164.815, truncated before comparison
    assert_eq!(scan(0, 165), 0);
    assert_eq!(scan(0, -1), 3);
}

#[test]
fn rejects_bad_layout_roi_and_flags() {
    let q = RatioQuery { rect: Rect { x1: 0, y1: 0, x2: 4, y2: 4 }, mode: 0, threshold: 16 };
    let data = [0_u8; 64];
    unsafe {
        assert_eq!(forma_pixels_ratio_hits(null(), 64, 4, 4, 16, &q), INVALID);
        assert_eq!(forma_pixels_ratio_hits(data.as_ptr(), data.len(), 4, 4, 16, null()), INVALID);
        assert_eq!(forma_pixels_ratio_hits(data.as_ptr(), 63, 4, 4, 16, &q), INVALID);
        assert_eq!(forma_pixels_ratio_hits(data.as_ptr(), 64, 4, 4, 15, &q), INVALID);
        assert_eq!(forma_pixels_ratio_hits(data.as_ptr(), 64, 4, 4, usize::MAX, &q), INVALID);
        assert_eq!(forma_pixels_ratio_hits(data.as_ptr(), 64, 0, 4, 16, &q), INVALID);
        assert_eq!(forma_pixels_ratio_hits(data.as_ptr(), 64, 4, 8193, 16, &q), INVALID);
        let q = RatioQuery { rect: Rect { x2: 5, ..q.rect }, ..q };
        assert_eq!(forma_pixels_ratio_hits(data.as_ptr(), 64, 4, 4, 16, &q), INVALID);
    }
    let frame = Frame { pixels: &data, w: 4, h: 4, stride: 16 };
    let mut out = [Cluster::default(); 1];
    assert_eq!(clusters(&frame, mask_query(q.rect, 1 << MODES), &mut out), Err(INVALID));
    assert_eq!(clusters(&frame, MaskQuery { step: 0, ..mask_query(q.rect, 1) }, &mut out), Err(INVALID));
    assert_eq!(Frame::bytes(MAX_BYTES + 1, 4, 4, 16), None);
}

#[test]
fn caps_work_before_touching_pixel_data() {
    let frame = Frame { pixels: &[], w: 2048, h: 2048, stride: 8192 };
    let rect = Rect { x1: 0, y1: 0, x2: 2048, y2: 2048 };
    assert_eq!(frame.grid(rect, 1, 1), Err(CAPACITY));
    assert_eq!(frame.grid(rect, 4, 4), Ok((512, 512)));
    let mut out = [Cluster::default(); 1];
    let q = MaskQuery { step: 4, cell: 1, ..mask_query(rect, 1) };
    assert_eq!(clusters(&frame, q, &mut out), Err(CAPACITY));
}
