//! Tier-1 pixel signals: blur, exposure, dHash, pocket-shot.

use image::{imageops, RgbaImage};
use serde::{Deserialize, Serialize};

/// Pixel-level quality signals computed in Rust on a downsampled thumbnail.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PixelSignals {
    /// Laplacian variance; lower = blurrier. Typical sharp photos > 100 on 256px.
    pub blur_variance: f32,
    /// Fraction of near-black pixels (0..1).
    pub dark_fraction: f32,
    /// Fraction of near-white / clipped pixels (0..1).
    pub bright_fraction: f32,
    /// Mean luminance 0..255.
    pub mean_luminance: f32,
    /// 64-bit difference hash.
    pub dhash: u64,
    /// Near-uniform frame (pocket / lens cover).
    pub is_pocket_shot: bool,
    /// How uniform (0..1); high → pocket.
    pub uniformity: f32,
}

/// Analyze an RGBA buffer (row-major, 4 bytes/pixel).
pub fn analyze_rgba(width: u32, height: u32, rgba: &[u8]) -> Result<PixelSignals, SignalError> {
    if width == 0 || height == 0 {
        return Err(SignalError::InvalidDimensions);
    }
    let expected = (width as usize)
        .checked_mul(height as usize)
        .and_then(|n| n.checked_mul(4))
        .ok_or(SignalError::InvalidDimensions)?;
    if rgba.len() < expected {
        return Err(SignalError::BufferTooShort {
            expected,
            got: rgba.len(),
        });
    }

    let img = RgbaImage::from_raw(width, height, rgba[..expected].to_vec())
        .ok_or(SignalError::InvalidDimensions)?;

    // Work on a fixed-size gray thumbnail for consistent thresholds.
    let thumb = imageops::resize(&img, 256, 256, imageops::FilterType::Triangle);
    let gray = to_luma(&thumb);

    let blur_variance = laplacian_variance(&gray, 256, 256);
    let (mean_luminance, dark_fraction, bright_fraction, uniformity) = exposure_stats(&gray);
    let dhash = compute_dhash(&img);
    let is_pocket_shot = uniformity > 0.92 || (dark_fraction > 0.85 && blur_variance < 20.0);

    Ok(PixelSignals {
        blur_variance,
        dark_fraction,
        bright_fraction,
        mean_luminance,
        dhash,
        is_pocket_shot,
        uniformity,
    })
}

#[derive(Debug, thiserror::Error)]
pub enum SignalError {
    #[error("invalid image dimensions")]
    InvalidDimensions,
    #[error("RGBA buffer too short: expected {expected}, got {got}")]
    BufferTooShort { expected: usize, got: usize },
}

fn to_luma(img: &RgbaImage) -> Vec<u8> {
    img.pixels()
        .map(|p| {
            // Rec. 601 luma
            ((p[0] as u32 * 299 + p[1] as u32 * 587 + p[2] as u32 * 114) / 1000) as u8
        })
        .collect()
}

/// 3x3 Laplacian variance as a blur proxy.
fn laplacian_variance(gray: &[u8], w: u32, h: u32) -> f32 {
    let w = w as usize;
    let h = h as usize;
    if w < 3 || h < 3 || gray.len() < w * h {
        return 0.0;
    }
    // Kernel: 0 1 0 / 1 -4 1 / 0 1 0
    let mut sum = 0.0f64;
    let mut sum_sq = 0.0f64;
    let mut n = 0u64;
    for y in 1..h - 1 {
        for x in 1..w - 1 {
            let i = y * w + x;
            let v =
                gray[i - w] as i32 + gray[i - 1] as i32 + gray[i + 1] as i32 + gray[i + w] as i32
                    - 4 * gray[i] as i32;
            let vf = v as f64;
            sum += vf;
            sum_sq += vf * vf;
            n += 1;
        }
    }
    if n == 0 {
        return 0.0;
    }
    let mean = sum / n as f64;
    ((sum_sq / n as f64) - mean * mean) as f32
}

fn exposure_stats(gray: &[u8]) -> (f32, f32, f32, f32) {
    if gray.is_empty() {
        return (0.0, 0.0, 0.0, 1.0);
    }
    let mut hist = [0u32; 256];
    let mut sum = 0u64;
    for &g in gray {
        hist[g as usize] += 1;
        sum += g as u64;
    }
    let n = gray.len() as f32;
    let mean = sum as f32 / n;
    let dark = hist[..16].iter().sum::<u32>() as f32 / n;
    let bright = hist[240..].iter().sum::<u32>() as f32 / n;

    // Uniformity: max bin / n (1 = solid color).
    let max_bin = *hist.iter().max().unwrap_or(&0) as f32;
    let uniformity = max_bin / n;

    (mean, dark, bright, uniformity)
}

/// 8x9 grayscale difference hash → 64 bits.
fn compute_dhash(img: &RgbaImage) -> u64 {
    let small = imageops::resize(img, 9, 8, imageops::FilterType::Triangle);
    let gray = to_luma(&small);
    let mut hash = 0u64;
    for y in 0..8 {
        for x in 0..8 {
            let left = gray[y * 9 + x];
            let right = gray[y * 9 + x + 1];
            if left > right {
                hash |= 1u64 << (y * 8 + x);
            }
        }
    }
    hash
}

/// Hamming distance between two dHashes.
pub fn dhash_distance(a: u64, b: u64) -> u32 {
    (a ^ b).count_ones()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(w: u32, h: u32, r: u8, g: u8, b: u8) -> Vec<u8> {
        let mut out = Vec::with_capacity((w * h * 4) as usize);
        for _ in 0..w * h {
            out.extend_from_slice(&[r, g, b, 255]);
        }
        out
    }

    #[test]
    fn pocket_shot_on_black() {
        let buf = solid(64, 64, 0, 0, 0);
        let s = analyze_rgba(64, 64, &buf).unwrap();
        assert!(s.is_pocket_shot);
        assert!(s.uniformity > 0.9);
    }

    #[test]
    fn sharp_checkerboard_has_high_blur_variance() {
        let mut buf = Vec::new();
        for y in 0..64u32 {
            for x in 0..64u32 {
                let v = if (x / 4 + y / 4) % 2 == 0 { 255 } else { 0 };
                buf.extend_from_slice(&[v, v, v, 255]);
            }
        }
        let s = analyze_rgba(64, 64, &buf).unwrap();
        assert!(s.blur_variance > 50.0, "got {}", s.blur_variance);
        assert!(!s.is_pocket_shot);
    }

    #[test]
    fn dhash_identical_for_same_image() {
        let buf = solid(32, 32, 100, 50, 200);
        let a = analyze_rgba(32, 32, &buf).unwrap();
        let b = analyze_rgba(32, 32, &buf).unwrap();
        assert_eq!(a.dhash, b.dhash);
        assert_eq!(dhash_distance(a.dhash, b.dhash), 0);
    }

    #[test]
    fn rejects_short_buffer() {
        assert!(analyze_rgba(10, 10, &[0u8; 10]).is_err());
    }
}
