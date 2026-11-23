use super::*;

fn pixel(bytes: &mut [u8], stride: usize, x: usize, y: usize, bgra: [u8; 4]) {
    let offset = y * stride + x * 4;
    bytes[offset..offset + 4].copy_from_slice(&bgra);
}

#[test]
fn warm_origin_sentinels_and_colour_edges() {
    let (w, h, stride) = (11, 7, 49);
    let mut pixels = vec![0xff; h as usize * stride];
    for (x, y, bgr) in [
        (1, 1, [94, 103, 120, 0]), // R minimum, R-B=26
        (3, 3, [94, 100, 120, 237]), // same cell, G-B=6
        (5, 1, [94, 104, 120, 91]), // R-G=16 (not strictly greater)
        (7, 1, [95, 102, 120, 0]), // R-B=25
        (9, 3, [93, 102, 119, 0]), // R below minimum
        (5, 5, [94, 99, 130, 0]), // G-B=5
        (7, 5, [60, 100, 135, 0]), // third column, second row
        (10, 5, [94, 103, 120, 0]), // x2 excluded
        (0, 1, [94, 103, 120, 0]), // outside ROI
    ] {
        pixel(&mut pixels, stride, x, y, bgr);
    }
    let frame = Frame { pixels: &pixels, w, h, stride };
    let q = WarmQuery { rect: Rect { x1: 1, y1: 1, x2: 10, y2: 7 }, cell: 3, step: 2 };
    let mut cells = [17; 21];
    assert_eq!(warm_grid(&frame, q, &mut cells, false), Ok(3));
    let mut expected = [0; 21];
    expected[0] = 2;
    expected[7] = 1;
    expected[20] = 17; // the caller can supply extra capacity
    assert_eq!(cells, expected);
    assert_eq!(warm_grid(&frame, q, &mut cells[..19], false), Err(CAPACITY));
    assert_eq!(cells, expected);

    let mut with_peak = [17; 24];
    assert_eq!(warm_grid(&frame, q, &mut with_peak, true), Ok(3));
    assert_eq!(&with_peak[..20], &cells[..20]);
    assert_eq!(&with_peak[20..], &[1, 1, 3, 17]);
}

#[test]
fn warm_peak_keeps_first_tie_and_visits_last_full_window() {
    let mut cells = [0; 6 * 5];
    cells[1] = 3;
    cells[29] = 3;
    assert_eq!(warm_peak(&cells, 6, 6), [1, 1, 3]);
    cells[1] = 0;
    assert_eq!(warm_peak(&cells, 6, 3), [4, 3, 3]);
    cells[29] = 2;
    assert_eq!(warm_peak(&cells, 6, 2), [0, 0, 0]);
    assert_eq!(warm_peak(&[3; 10], 2, 30), [0, 0, 0]);
    assert_eq!(warm_peak(&[3; 12], 6, 36), [0, 0, 0]);
}

#[test]
fn motion_rgb_threshold_own_zone_and_cells() {
    let (w, h, stride) = (100, 100, 403);
    let before = vec![96u8; h as usize * stride];
    let mut now = before.clone();
    // Test the actual strict cutoffs x>33, x<62 and y>68.
    for (x, y, rgb) in [(33, 70, 78), (33, 71, 78), (32, 71, 79), (32, 70, 77),
                        (34, 70, 78), (50, 68, 78), (50, 69, 78), (62, 70, 78), (63, 68, 0)] {
        pixel(&mut now, stride, x, y, [96 + rgb, 96, 96, 0]);
    }
    let previous = Frame { pixels: &before, w, h, stride };
    let frame = Frame { pixels: &now, w, h, stride };
    let q = MotionQuery { rect: Rect { x1: 30, y1: 66, x2: 64, y2: 75 }, step: 1 };
    let mut cells = [MotionCell::default(); 85];
    assert_eq!(motion_cells(&frame, &previous, q, &mut cells), Ok(5));
    assert_eq!(cells[35], MotionCell { x1: 32, y1: 70, x2: 33, y2: 71, n: 3 });
    assert_eq!(cells[27], MotionCell { x1: 50, y1: 68, x2: 50, y2: 68, n: 1 });
    assert_eq!(cells[50], MotionCell { x1: 62, y1: 70, x2: 62, y2: 70, n: 1 });
    assert_eq!(cells.iter().filter(|c| c.n != 0).count(), 3);
    assert_eq!(motion_cells(&frame, &frame, q, &mut cells), Ok(0));
    assert!(cells.iter().all(|c| c.n == 0));
}

#[test]
fn motion_widespread_change_is_empty_not_partial() {
    let (w, h, stride) = (100, 100, 405);
    let q = MotionQuery { rect: Rect { x1: 3, y1: 5, x2: 96, y2: 97 }, step: 3 };
    let gray = vec![55; h as usize * stride];
    let bright = vec![205; gray.len()];
    let a = Frame { pixels: &gray, w, h, stride };
    let b = Frame { pixels: &bright, w, h, stride };
    let mut cells = [MotionCell::default(); 16 * 16];
    assert_eq!(motion_cells(&a, &b, q, &mut cells), Ok(0));
    assert!(cells.iter().all(|c| c.n == 0));
}

#[test]
fn combat_abi_layout_rejects_bad_buffers_and_capacity() {
    assert_eq!(std::mem::size_of::<WarmQuery>(), 24);
    assert_eq!(std::mem::size_of::<MotionQuery>(), 20);
    assert_eq!(std::mem::size_of::<MotionCell>(), 20);
    assert_eq!(std::mem::offset_of!(MotionCell, n), 16);
    let pixels = [0u8; 96];
    let r = Rect { x1: 1, y1: 1, x2: 3, y2: 4 };
    let q = WarmQuery { rect: r, cell: 1, step: 1 };
    let m = MotionQuery { rect: r, step: 1 };
    let mut warm = [17u32; 1];
    let mut short_peak = [19u32; 22]; // 4x5 cells + only two of the three peak slots
    let mut motion = [MotionCell::default(); 1];
    // SAFETY: the inputs and outputs are initialized and disjoint. Bad layouts
    // and short output/previous capacities are rejected before any access to them.
    unsafe {
        assert_eq!(forma_pixels_warm_grid(pixels.as_ptr(), 96, 4, 5, 19, &q,
            warm.as_mut_ptr(), warm.len()), CAPACITY);
        assert_eq!(forma_pixels_warm_grid(pixels.as_ptr(), 96, 4, 5, 15, &q,
            warm.as_mut_ptr(), warm.len()), INVALID);
        assert_eq!(forma_pixels_warm_grid_peak(pixels.as_ptr(), 96, 4, 5, 19, &q,
            short_peak.as_mut_ptr(), short_peak.len()), CAPACITY);
        assert_eq!(forma_pixels_motion_cells(pixels.as_ptr(), 96, 4, 5, 19, pixels.as_ptr(), 94,
            &m, motion.as_mut_ptr(), motion.len()), INVALID);
        assert_eq!(forma_pixels_motion_cells(pixels.as_ptr(), 96, 4, 5, 19, pixels.as_ptr(), 96,
            &m, motion.as_mut_ptr(), motion.len()), CAPACITY);
    }
    assert_eq!(warm, [17]);
    assert_eq!(short_peak, [19; 22]);
    assert_eq!(motion, [MotionCell::default()]);
}
