//! Read-only BGRX scans for FORMA. No capture, device input, or game state.

use std::collections::BTreeMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::slice;

mod combat;

const MAX_SIDE: u32 = 8192;
const MAX_BYTES: usize = 128 * 1024 * 1024;
const MAX_SAMPLES: usize = 262_144;
const MAX_TILES: u64 = 131_072;
const MAX_CLUSTERS: usize = 4096;
const INVALID: i32 = -1;
const CAPACITY: i32 = -2;
const PANIC: i32 = -3;

const CHEST_GOLD: usize = 0;
const CHEST_RARE: usize = 1;
const GOLD: usize = 2;
const CREAM: usize = 3;
const GREEN: usize = 4;
const BLUE: usize = 5;
const PURPLE: usize = 6;
const RED: usize = 7;
const WHITE: usize = 8;
const PURE: usize = 9;
const YELLOW: usize = 10;
const MODES: usize = 11;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Rect {
    x1: u32,
    y1: u32,
    x2: u32, // exclusive
    y2: u32, // exclusive
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MaskQuery {
    rect: Rect,
    cell: u32,
    step: u32,
    min_cells: u32,
    modes: u32,
    yellow: [i32; 4], // R min, G min, B max, |R-G| max
    cream: [i32; 3],  // R min, B min, B max
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PlateQuery {
    rect: Rect,
    step_x: u32,
    step_y: u32,
    mode: u32, // 0: yellow, 1: light, 2: light or lavender, 3: red
    yellow: [i32; 4],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RatioQuery {
    rect: Rect,
    mode: u32, // 0: bright, 1: dark
    threshold: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Cluster {
    mode: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    n: u32,
    cx: u32,
    cy: u32,
    cells: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RowRun {
    run: u32,
    cx: u32,
}

struct Frame<'a> {
    pixels: &'a [u8],
    w: u32,
    h: u32,
    stride: usize,
}

impl Frame<'_> {
    fn bytes(len: usize, w: u32, h: u32, stride: usize) -> Option<usize> {
        if !(2..=MAX_SIDE).contains(&w) || !(2..=MAX_SIDE).contains(&h)
            || stride < w as usize * 4 || len > MAX_BYTES
        {
            return None;
        }
        stride.checked_mul(h as usize).filter(|&n| n <= len)
    }

    fn grid(&self, rect: Rect, sx: u32, sy: u32) -> Result<(usize, usize), i32> {
        if rect.x1 >= rect.x2 || rect.y1 >= rect.y2 || rect.x2 > self.w || rect.y2 > self.h
            || !(1..=MAX_SIDE).contains(&sx) || !(1..=MAX_SIDE).contains(&sy)
        {
            return Err(INVALID);
        }
        let cols = (rect.x2 - rect.x1).div_ceil(sx) as usize;
        let rows = (rect.y2 - rect.y1).div_ceil(sy) as usize;
        if rows * cols > MAX_SAMPLES {
            return Err(CAPACITY);
        }
        Ok((cols, rows))
    }
}

#[inline]
fn rgb(row: &[u8], x: u32) -> (i32, i32, i32) {
    let i = x as usize * 4;
    (row[i + 2].into(), row[i + 1].into(), row[i].into())
}

#[inline]
fn yellow(r: i32, g: i32, b: i32, limits: [i32; 4]) -> bool {
    let [r_min, g_min, b_max, delta] = limits;
    b <= b_max && r >= r_min && g >= g_min && (r - g).abs() <= delta
}

fn color(r: i32, g: i32, b: i32, q: &MaskQuery) -> Option<usize> {
    let has = |index| q.modes & (1_u32 << index) != 0;
    if has(CHEST_GOLD) && r >= 150 && (85..=232).contains(&g) && b <= 98
        && r - b >= 88 && (0..=125).contains(&(r - g))
    {
        return Some(CHEST_GOLD);
    }
    if has(CHEST_RARE) && b >= 210 && (148..=242).contains(&g) && r <= 98
        && b - r >= 120 && g - r >= 62
    {
        return Some(CHEST_RARE);
    }
    // Keep the AHK priority exactly: requesting gold disables cream,
    // even when this particular pixel does not qualify as gold.
    if has(GOLD) {
        if r >= 140 && (80..=155).contains(&g) && b <= 85 && r - b >= 90 {
            return Some(GOLD);
        }
    } else if has(CREAM) {
        let [r_min, b_min, b_max] = q.cream;
        if (b_min..=b_max).contains(&b) && r >= r_min && g >= r_min.saturating_sub(10)
            && (r - g).abs() <= 25
        {
            return Some(CREAM);
        }
    }
    if has(GREEN) && g >= 120 && g - r >= 40 && g - b >= 40 {
        Some(GREEN)
    } else if has(BLUE) && b >= 140 && b - r >= 55 && b - g >= 20 {
        Some(BLUE)
    } else if has(PURPLE) && r >= 105 && b >= 145 && b - g >= 55 && r - g >= 35 {
        Some(PURPLE)
    } else if has(RED) && r >= 110 && r - g >= 45 && r - b >= 45 {
        Some(RED)
    } else if has(WHITE) && r >= 215 && g >= 215 && b >= 205 && (r - b).abs() <= 45 {
        Some(WHITE)
    } else if has(PURE) && r >= 245 && g >= 245 && b >= 238 {
        Some(PURE)
    } else if has(YELLOW) && yellow(r, g, b, q.yellow) {
        Some(YELLOW)
    } else {
        None
    }
}

#[derive(Default)]
struct Cell {
    n: u32,
    sx: u64,
    sy: u64,
}

fn clusters(frame: &Frame<'_>, q: MaskQuery, out: &mut [Cluster]) -> Result<usize, i32> {
    if !(1..=MAX_SIDE).contains(&q.cell) || q.min_cells == 0
        || q.modes == 0 || q.modes >= 1 << MODES
    {
        return Err(INVALID);
    }
    frame.grid(q.rect, q.step, q.step)?;
    // Sparse per-colour grids. Limit their worst-case population separately
    // from the number of sampled pixels, so one FFI call stays bounded.
    let tile_cols = (q.rect.x2 - 1) / q.cell - q.rect.x1 / q.cell + 1;
    let tile_rows = (q.rect.y2 - 1) / q.cell - q.rect.y1 / q.cell + 1;
    if u64::from(tile_cols) * u64::from(tile_rows) * u64::from(q.modes.count_ones()) > MAX_TILES {
        return Err(CAPACITY);
    }
    let mut grids: [BTreeMap<(u32, u32), Cell>; MODES] = Default::default();
    for y in (q.rect.y1..q.rect.y2).step_by(q.step as usize) {
        let start = y as usize * frame.stride;
        let row = &frame.pixels[start..start + frame.w as usize * 4];
        for x in (q.rect.x1..q.rect.x2).step_by(q.step as usize) {
            let (r, g, b) = rgb(row, x);
            if let Some(mode) = color(r, g, b, &q) {
                let entry = grids[mode].entry((y / q.cell, x / q.cell)).or_default();
                entry.n += 1;
                entry.sx += u64::from(x);
                entry.sy += u64::from(y);
            }
        }
    }
    let mut count = 0;
    let mut pending = Vec::new();
    for (mode, grid) in grids.iter_mut().enumerate() {
        // Sort by the least (cell_y, cell_x) in each component, like the
        // integer keys of the AHK map. Ties in later scoring keep their order.
        while let Some(((y, x), mut total)) = grid.pop_first() {
            let mut bounds = (x, y, x, y);
            let mut cells = 1;
            pending.push((y, x));
            while let Some((cy, cx)) = pending.pop() {
                for ny in cy.saturating_sub(1)..=cy + 1 {
                    for nx in cx.saturating_sub(1)..=cx + 1 {
                        if let Some(cell) = grid.remove(&(ny, nx)) {
                            pending.push((ny, nx));
                            bounds.0 = bounds.0.min(nx);
                            bounds.1 = bounds.1.min(ny);
                            bounds.2 = bounds.2.max(nx);
                            bounds.3 = bounds.3.max(ny);
                            total.n += cell.n;
                            total.sx += cell.sx;
                            total.sy += cell.sy;
                            cells += 1;
                        }
                    }
                }
            }
            if cells >= q.min_cells {
                let slot = out.get_mut(count).ok_or(CAPACITY)?;
                let (x1, y1, x2, y2) = bounds;
                let n = u64::from(total.n);
                *slot = Cluster {
                    mode: mode as u32,
                    x: x1 * q.cell,
                    y: y1 * q.cell,
                    w: (x2 - x1 + 1) * q.cell,
                    h: (y2 - y1 + 1) * q.cell,
                    n: total.n,
                    cx: ((total.sx + n / 2) / n) as u32,
                    cy: ((total.sy + n / 2) / n) as u32,
                    cells,
                };
                count += 1;
            }
        }
    }
    Ok(count)
}

fn plate_rows(frame: &Frame<'_>, q: PlateQuery, out: &mut [RowRun]) -> Result<usize, i32> {
    if q.mode > 3 {
        return Err(INVALID);
    }
    let (_, rows) = frame.grid(q.rect, q.step_x, q.step_y)?;
    if out.len() < rows {
        return Err(CAPACITY);
    }
    for (y, dst) in (q.rect.y1..q.rect.y2).step_by(q.step_y as usize).zip(out) {
        let offset = y as usize * frame.stride;
        let row = &frame.pixels[offset..offset + frame.w as usize * 4];
        let mut best = RowRun::default();
        let mut run = 0;
        let mut start = 0;
        for x in (q.rect.x1..q.rect.x2).step_by(q.step_x as usize) {
            let (r, g, b) = rgb(row, x);
            let hit = match q.mode {
                0 => yellow(r, g, b, q.yellow),
                3 => r >= 160 && g <= 82 && b <= 92 && r - g >= 92 && r - b >= 82,
                _ => (r >= 188 && g >= 188 && b >= 192 && r.max(g).max(b) - r.min(g).min(b) <= 36)
                    || (q.mode == 2 && r >= 150 && g >= 158 && b >= 185 && (0..=72).contains(&(b - r))),
            };
            if hit {
                if run == 0 {
                    start = x;
                }
                run += q.step_x;
                if run > best.run {
                    best = RowRun { run, cx: start + run / 2 };
                }
            } else {
                run = 0;
            }
        }
        *dst = best;
    }
    Ok(rows)
}

fn ratio_hits(frame: &Frame<'_>, q: RatioQuery) -> Result<usize, i32> {
    const STEP: u32 = 4;
    if q.mode > 1 {
        return Err(INVALID);
    }
    frame.grid(q.rect, STEP, STEP)?;
    let mut n = 0;
    for y in (q.rect.y1..q.rect.y2).step_by(STEP as usize) {
        let offset = y as usize * frame.stride;
        let row = &frame.pixels[offset..offset + frame.w as usize * 4];
        for x in (q.rect.x1..q.rect.x2).step_by(STEP as usize) {
            let (r, g, b) = rgb(row, x);
            let hit = if q.mode == 0 {
                (r * 299 + g * 587 + b * 114) / 1000 >= q.threshold
            } else {
                r + g + b < 120
            };
            n += usize::from(hit);
        }
    }
    Ok(n)
}

#[unsafe(no_mangle)]
pub extern "C" fn forma_pixels_abi() -> u32 {
    1
}

fn call(f: impl FnOnce() -> Result<usize, i32>) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(n)) => n as i32,
        Ok(Err(code)) => code,
        Err(_) => PANIC,
    }
}

// The caller must provide the allocation described by non-null `pixels`.
unsafe fn read_frame<'a>(pixels: *const u8, len: usize, w: u32, h: u32, stride: usize) -> Result<Frame<'a>, i32> {
    let bytes = Frame::bytes(len, w, h, stride).ok_or(INVALID)?;
    if pixels.is_null() {
        return Err(INVALID);
    }
    // `Frame::bytes` bounds this to 128 MiB, below isize::MAX on supported hosts.
    let pixels = unsafe { slice::from_raw_parts(pixels, bytes) };
    Ok(Frame { pixels, w, h, stride })
}

/// # Safety
/// Non-null `pixels` must describe one readable, immutable allocation of `len`
/// bytes for valid layouts. Non-null `query` must point to a fully initialized
/// ABI-v1 `MaskQuery`. Non-null, aligned `out` must point to `cap` initialized
/// writable records (for accepted capacities), disjoint from the inputs. No
/// pointer or slice lives past this synchronous call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn forma_pixels_clusters(
    pixels: *const u8,
    len: usize,
    w: u32,
    h: u32,
    stride: usize,
    query: *const MaskQuery,
    out: *mut Cluster,
    cap: usize,
) -> i32 {
    call(|| {
        if query.is_null() || out.is_null() || !out.is_aligned()
            || !(1..=MAX_CLUSTERS).contains(&cap)
        {
            return Err(INVALID);
        }
        // SAFETY: sizes and alignment checked here and in read_frame;
        // allocation validity and disjointness are the caller's contract.
        let frame = unsafe { read_frame(pixels, len, w, h, stride)? };
        let query = unsafe { query.read_unaligned() };
        let out = unsafe { slice::from_raw_parts_mut(out, cap) };
        clusters(&frame, query, out)
    })
}

/// # Safety
/// Same buffer requirements as `forma_pixels_clusters`, but `query` points
/// to a `PlateQuery` and the output records are of type `RowRun`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn forma_pixels_rows(
    pixels: *const u8,
    len: usize,
    w: u32,
    h: u32,
    stride: usize,
    query: *const PlateQuery,
    out: *mut RowRun,
    cap: usize,
) -> i32 {
    call(|| {
        if query.is_null() || out.is_null() || !out.is_aligned()
            || !(1..=MAX_SIDE as usize).contains(&cap)
        {
            return Err(INVALID);
        }
        // SAFETY: same lifetime and buffer contract as the mask entry point.
        let frame = unsafe { read_frame(pixels, len, w, h, stride)? };
        let query = unsafe { query.read_unaligned() };
        let out = unsafe { slice::from_raw_parts_mut(out, cap) };
        plate_rows(&frame, query, out)
    })
}

/// # Safety
/// Same read-only frame requirements as `forma_pixels_clusters`. Non-null
/// `query` must point to a fully initialized `RatioQuery`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn forma_pixels_ratio_hits(
    pixels: *const u8,
    len: usize,
    w: u32,
    h: u32,
    stride: usize,
    query: *const RatioQuery,
) -> i32 {
    call(|| {
        if query.is_null() {
            return Err(INVALID);
        }
        // SAFETY: same read-only buffer contract as the other entry points.
        let frame = unsafe { read_frame(pixels, len, w, h, stride)? };
        ratio_hits(&frame, unsafe { query.read_unaligned() })
    })
}

#[cfg(test)]
mod tests;
