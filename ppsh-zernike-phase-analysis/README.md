# PPSH Phase and Zernike Analysis

This repository contains MATLAB scripts for extracting wrapped phase maps from PPSH/LUCID hologram TIFF images and fitting the phase distributions with Noll-ordered Zernike polynomials.

This offline workflow uses the same four-step PPSI phase reconstruction formula as the real-time LUCID PPSI viewer in the parent repository.

The default workflow analyzes absolute phase maps. If a change from a reference frame is needed, compute the difference between Zernike coefficients after fitting:

```matlab
delta_coeff = coeff(frame) - coeff(reference_frame);
```

## Files

| File | Purpose |
| --- | --- |
| `A_extract_phase_ppsh.m` | Extract wrapped phase maps from hologram TIFF images in `source/`. |
| `B_smooth_phase.m` | Smooth wrapped phase maps using an `M x M` complex-field average. |
| `C_fit_zernike.m` | Fit Zernike coefficients to selected phase maps. |
| `D_plot_zernike.m` | Export selected Zernike mode distributions and all-coefficient bar charts. |
| `Unwrap_TIE_DCT_Iter.m` | Optional phase unwrapping routine based on TIE-DCT. |

## Directory Structure

```text
.
├── source/                  # Input hologram TIFF files
├── A_extract_phase_ppsh.m
├── B_smooth_phase.m
├── C_fit_zernike.m
├── D_plot_zernike.m
└── Unwrap_TIE_DCT_Iter.m
```

Generated output folders such as `phase/`, `phase_16_16/`, and `zernike/` are ignored by Git.

## Workflow

Run the scripts in this order from MATLAB:

```matlab
A_extract_phase_ppsh
B_smooth_phase
C_fit_zernike
D_plot_zernike
```

### 1. Phase Extraction

`A_extract_phase_ppsh.m` reads TIFF images from `source/` and saves wrapped phase TIFFs to `phase/`.

The complex amplitude is calculated from the PPSH polarization sub-images:

```matlab
complex_amp = ((I90 - I0) + 1i * (I135 - I45)) / 4;
phase = angle(complex_amp);
```

The saved phase is wrapped in the range `[-pi, pi]` and encoded as `uint16`.

### 2. Phase Smoothing

`B_smooth_phase.m` smooths phase maps on the unit complex field:

```matlab
smoothed = angle(smoothComplex(exp(1i * phase), M));
```

This avoids direct averaging across the `-pi/pi` wrapping boundary. The default smoothing size is:

```matlab
M = 16;
```

The output is saved to `phase_16_16/`.

### 3. Zernike Fitting

`C_fit_zernike.m` crops a fixed square ROI, applies a circular mask, optionally unwraps the phase, and fits Zernike terms Z1-Z21.

Key parameters:

```matlab
input_dir = fullfile(root_dir, "phase_16_16");
center_xy = [648, 648];
roi_size = 1024;
max_zernike_index = 21;
unwrap_phase = true;
```

The fitting core is linear least squares:

```matlab
coeff = basis(valid, :) \ values(valid);
```

This solves:

```text
phase(x, y) ≈ sum_j coeff_j * Z_j(x, y)
```

Results are saved in:

```text
phase_16_16/zernike/
├── zernike_coefficients_Z1_to_Z21.csv
├── zernike_fit_metrics.csv
└── zernike_fit_settings.mat
```

### 4. Plotting

`D_plot_zernike.m` reads the coefficient CSV and outputs:

- selected Noll-index Zernike mode distributions
- all-coefficient bar charts for each frame

Default selected modes:

```matlab
selected_noll_indices = [4 11];
```

Output figures are saved to:

```text
phase_16_16/zernike/plots/
```

## Zernike Convention

The scripts use a Noll-like ordering up to Z21. The basis functions are RMS-normalized on the unit disk:

```matlab
sqrt(n + 1)         % m = 0
sqrt(2 * (n + 1))   % m ~= 0
```

With this normalization, each coefficient is expressed in radians and represents the weight of that Zernike mode over the chosen circular ROI.

Important: Zernike coefficients depend on the chosen ROI center, ROI size, circular aperture, and sign convention. These settings should be reported when publishing results.

## Requirements

- MATLAB
- Image Processing Toolbox
- `Unwrap_TIE_DCT_Iter.m` dependencies such as DCT functions

## Notes on Phase Unwrapping

`Unwrap_TIE_DCT_Iter.m` is an external TIE-DCT phase unwrapping implementation by Zixin Zhao. Keep its original copyright and license text when redistributing this repository.

If the phase variation is already within `[-pi, pi]`, compare results with:

```matlab
unwrap_phase = false;
```

to check whether unwrapping affects low-order Zernike coefficients.

## Reproducibility Notes

For publication, report at least:

- input phase type: absolute wrapped phase
- smoothing size `M`
- ROI center `center_xy`
- ROI size `roi_size`
- maximum Zernike index
- whether unwrapping was enabled
- Zernike ordering and normalization
