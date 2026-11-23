//! Pixel measurements only. Frame provenance and action policy stay in AHK.

use super::{CAPACITY, Frame, INVALID, MAX_SIDE, MAX_TILES, Rect, call, read_frame, rgb};
use std::slice;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct WarmQuery {
    rect: Rect,
    cell: u32,
    step: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MotionQuery {
    rect: Rect,
    step: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MotionCell {
    x1: u32,
    y1: u32,
    x2: u32, // Last sample, not the exclusive rectangle edge.
    y2: u32,
    n: u32,
}

fn warm_grid(frame: &Frame<'_>, q: WarmQuery, out: &mut [u32]) -> Result<usize, i32> {
    if !(1..=MAX_SIDE).contains(&q.cell) {
        return Err(INVALID);
    }
    frame.grid(q.rect, q.step, q.step)?;
    let Rect { x1, y1, x2, y2 } = q.rect;
    // Preserve the two sentinel cells used by the AHK 3x3 window search.
    let cols = ((x2 - x1) / q.cell + 2) as usize;
    let rows = ((y2 - y1) / q.cell + 2) as usize;
    let cells = out.get_mut(..cols * rows).ok_or(CAPACITY)?;
    cells.fill(0);
    let mut count = 0;
    for y in (y1..y2).step_by(q.step as usize) {
        let offset = y as usize * frame.stride;
        let row = &frame.pixels[offset..offset + frame.w as usize * 4];
        let base = ((y - y1) / q.cell) as usize * cols;
        for x in (x1..x2).step_by(q.step as usize) {
            let (r, g, b) = rgb(row, x);
            if r >= 120 && r > g + 16 && g >= b + 6 && r - b >= 26
                && !(r >= 232 && g >= 232 && b >= 225)
            {
                cells[base + ((x - x1) / q.cell) as usize] += 1;
                count += 1;
            }
        }
    }
    Ok(count)
}

fn motion_cells(
    frame: &Frame<'_>,
    previous: &Frame<'_>,
    q: MotionQuery,
    out: &mut [MotionCell],
) -> Result<usize, i32> {
    let (nx, ny) = frame.grid(q.rect, q.step, q.step)?;
    let Rect { x1, y1, x2, y2 } = q.rect;
    let cell = q.step * 2;
    let cols = (x2 - x1).div_ceil(cell) as usize;
    let rows = (y2 - y1).div_ceil(cell) as usize;
    let cells = out.get_mut(..cols * rows).ok_or(CAPACITY)?;
    cells.fill(MotionCell::default());
    let sector_min = (nx * ny / 96).max(7);
    let mut sectors = [0usize; 12];
    let mut spread = 0;
    let mut hits = 0;
    // Match the strict boundaries of IsOwnPlayerZone(shot, x, y) without a box.
    let left = f64::from(frame.w) * 0.33;
    let right = f64::from(frame.w) * 0.62;
    let bottom = f64::from(frame.h) * 0.68;
    for y in (y1..y2).step_by(q.step as usize) {
        let offset = y as usize * frame.stride;
        let end = offset + frame.w as usize * 4;
        let row = &frame.pixels[offset..end];
        let old = &previous.pixels[offset..end];
        let base = ((y - y1) / cell) as usize * cols;
        let sector_row = ((y - y1) * 3 / (y2 - y1)) as usize * 4;
        for x in (x1..x2).step_by(q.step as usize) {
            // The unused fourth byte and row padding are never sampled.
            let (r, g, b) = rgb(row, x);
            let (pr, pg, pb) = rgb(old, x);
            if r.abs_diff(pr) + g.abs_diff(pg) + b.abs_diff(pb) < 78
                || (f64::from(x) > left && f64::from(x) < right && f64::from(y) > bottom)
            {
                continue;
            }
            let sector = &mut sectors[sector_row + ((x - x1) * 4 / (x2 - x1)) as usize];
            *sector += 1;
            if *sector == sector_min {
                spread += 1;
                if spread >= 6 {
                    cells.fill(MotionCell::default());
                    return Ok(0);
                }
            }
            let c = &mut cells[base + ((x - x1) / cell) as usize];
            if c.n == 0 {
                *c = MotionCell { x1: x, y1: y, x2: x, y2: y, n: 1 };
            } else {
                c.x1 = c.x1.min(x);
                c.x2 = c.x2.max(x);
                c.y2 = y;
                c.n += 1;
            }
            hits += 1;
        }
    }
    Ok(hits)
}

/// Fill the row-major warm grid. Return the total number of matching samples.
///
/// # Safety
/// Same buffer contract as `forma_pixels_clusters`. `query` points to an
/// initialized `WarmQuery`; `out` has `cap` initialized aligned `u32` values.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn forma_pixels_warm_grid(
    pixels: *const u8,
    len: usize,
    w: u32,
    h: u32,
    stride: usize,
    query: *const WarmQuery,
    out: *mut u32,
    cap: usize,
) -> i32 {
    call(|| {
        if query.is_null() || out.is_null() || !out.is_aligned()
            || !(1..=MAX_TILES as usize).contains(&cap)
        {
            return Err(INVALID);
        }
        let frame = unsafe { read_frame(pixels, len, w, h, stride)? };
        let query = unsafe { query.read_unaligned() };
        let out = unsafe { slice::from_raw_parts_mut(out, cap) };
        warm_grid(&frame, query, out)
    })
}

/// Fill the row-major motion grid and return the number of changed samples.
/// Widespread change is a successful negative reading (zero, with empty cells).
///
/// # Safety
/// Both read-only input buffers satisfy the same contract as `pixels` in
/// `forma_pixels_clusters`, with the same dimensions and stride. `query`
/// points to an initialized `MotionQuery`. `out` is a disjoint, aligned array
/// of `cap` initialized writable `MotionCell` records. No pointers are retained.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn forma_pixels_motion_cells(
    pixels: *const u8,
    len: usize,
    w: u32,
    h: u32,
    stride: usize,
    previous: *const u8,
    previous_len: usize,
    query: *const MotionQuery,
    out: *mut MotionCell,
    cap: usize,
) -> i32 {
    call(|| {
        if query.is_null() || out.is_null() || !out.is_aligned()
            || !(1..=MAX_TILES as usize).contains(&cap)
        {
            return Err(INVALID);
        }
        let frame = unsafe { read_frame(pixels, len, w, h, stride)? };
        let previous = unsafe { read_frame(previous, previous_len, w, h, stride)? };
        let query = unsafe { query.read_unaligned() };
        let out = unsafe { slice::from_raw_parts_mut(out, cap) };
        motion_cells(&frame, &previous, query, out)
    })
}

#[cfg(test)]
mod tests;
