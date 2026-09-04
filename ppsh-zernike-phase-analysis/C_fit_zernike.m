function C_fit_zernike()
% # C. Fit Zernike coefficients
% Fit Noll-ordered Zernike terms to wrapped or unwrapped phase maps in a fixed
% circular ROI. The fitting core is ordinary least squares: coeff = Z \ phase.

root_dir = fileparts(mfilename("fullpath"));
input_dir = fullfile(root_dir, "phase_16_16");
output_dir = fullfile(input_dir, "zernike");

frames = [];          % Example: [30 40 50]. Empty [] uses frame_start:frame_step:frame_end.
frame_start = 30;
frame_end = 80;
frame_step = 10;
file_pattern = "input_%04d_phase_16_16.tif";

center_xy = [648, 648];
roi_size = 1024;
max_zernike_index = 21;
unwrap_phase = true;

ensureDir(output_dir);
if unwrap_phase
    addpath(root_dir);
end

[files, frames] = selectPhaseFiles(input_dir, frames, frame_start, frame_end, frame_step, file_pattern);
[rho, theta, mask] = buildPolarGrid(roi_size);
[basis, labels] = buildZernikeBasis(rho(mask), theta(mask), max_zernike_index);

rows = cell(numel(files), 1);
metrics = table('Size', [numel(files) 7], ...
    'VariableTypes', {'double', 'string', 'double', 'double', 'double', 'double', 'double'}, ...
    'VariableNames', {'frame', 'file_name', 'x_min', 'y_min', 'x_max', 'y_max', 'residual_rms_rad'});

for k = 1:numel(files)
    phase_path = files(k);
    frame = extractFrameNumber(phase_path);
    wrapped = readPhaseTiff(phase_path);
    [roi_phase, rect] = cropCentered(wrapped, center_xy, roi_size);

    fit_phase = roi_phase;
    if unwrap_phase
        if exist("Unwrap_TIE_DCT_Iter", "file") == 2
            fit_phase = Unwrap_TIE_DCT_Iter(roi_phase);
        else
            warning("Unwrap_TIE_DCT_Iter was not found. Fitting the wrapped phase.");
        end
    end

    values = fit_phase(mask);
    valid = isfinite(values);
    coeff = basis(valid, :) \ values(valid);

    recon = nan(roi_size, roi_size);
    recon(mask) = basis * coeff;
    residual = fit_phase - recon;

    [~, stem] = fileparts(phase_path);
    rows{k} = table(repmat(frame, max_zernike_index, 1), ...
        repmat(string(stem), max_zernike_index, 1), (1:max_zernike_index).', ...
        labels(:), coeff(:), ...
        'VariableNames', {'frame', 'file_name', 'noll_index', 'term', 'coefficient_rad'});

    metrics.frame(k) = frame;
    metrics.file_name(k) = string(stem);
    metrics.x_min(k) = rect(1);
    metrics.y_min(k) = rect(2);
    metrics.x_max(k) = rect(3);
    metrics.y_max(k) = rect(4);
    metrics.residual_rms_rad(k) = rmsFinite(residual(mask));
    fprintf("Frame %g: residual RMS %.6f rad\n", frame, metrics.residual_rms_rad(k));
end

coefficients = vertcat(rows{:});
writetable(coefficients, fullfile(output_dir, "zernike_coefficients_Z1_to_Z21.csv"));
writetable(metrics, fullfile(output_dir, "zernike_fit_metrics.csv"));
save(fullfile(output_dir, "zernike_fit_settings.mat"), ...
    "input_dir", "output_dir", "frames", "frame_start", "frame_end", "frame_step", ...
    "file_pattern", "center_xy", "roi_size", "max_zernike_index", "unwrap_phase", ...
    "mask", "rho", "theta");

fprintf("Saved Zernike results to:\n%s\n", output_dir);
end

function [files, frames] = selectPhaseFiles(input_dir, frames, frame_start, frame_end, frame_step, pattern)
if ~isempty(frames)
    files = filesFromFrames(input_dir, frames, pattern);
    return;
end
if isempty(frame_start) && isempty(frame_end)
    listing = listTiffFiles(input_dir);
    files = strings(numel(listing), 1);
    frames = nan(1, numel(listing));
    for k = 1:numel(listing)
        files(k) = fullfile(listing(k).folder, listing(k).name);
        frames(k) = extractFrameNumber(files(k));
    end
    return;
end
if isempty(frame_step) || frame_step <= 0
    error("frame_step must be a positive number.");
end
frames = frame_start:frame_step:frame_end;
files = filesFromFrames(input_dir, frames, pattern);
end

function files = filesFromFrames(input_dir, frames, pattern)
files = strings(numel(frames), 1);
for k = 1:numel(frames)
    files(k) = fullfile(input_dir, sprintf(pattern, frames(k)));
    if ~isfile(files(k))
        error("Input file was not found: %s", files(k));
    end
end
end

function phase = readPhaseTiff(path)
img = imread(path);
if ndims(img) == 3
    img = img(:, :, 1);
end
if isa(img, "uint16")
    phase = double(img) / 65535 * (2 * pi) - pi;
else
    phase = double(img);
end
end

function [roi, rect] = cropCentered(img, center_xy, roi_size)
[height, width] = size(img);
half = floor(roi_size / 2);
cx = center_xy(1);
cy = center_xy(2);
x1 = max(1, round(cx - half));
y1 = max(1, round(cy - half));
x2 = min(width, x1 + roi_size - 1);
y2 = min(height, y1 + roi_size - 1);
x1 = max(1, x2 - roi_size + 1);
y1 = max(1, y2 - roi_size + 1);
roi = img(y1:y2, x1:x2);
rect = [x1, y1, x2, y2];
end

function [rho, theta, mask] = buildPolarGrid(roi_size)
c = (roi_size + 1) / 2;
radius = min([c - 1, roi_size - c]);
[xx, yy] = meshgrid(1:roi_size, 1:roi_size);
x = (xx - c) / radius;
y = (yy - c) / radius;
rho = hypot(x, y);
theta = atan2(y, x);
mask = rho <= 1;
end

function [basis, labels] = buildZernikeBasis(rho, theta, max_j)
terms = nollTerms();
if max_j > size(terms, 1)
    error("This script defines Zernike terms only up to Z%d.", size(terms, 1));
end
basis = zeros(numel(rho), max_j);
labels = strings(max_j, 1);
for j = 1:max_j
    n = terms(j, 1);
    m = terms(j, 2);
    s = terms(j, 3);
    if m == 0
        z = sqrt(n + 1) * radialZernike(n, 0, rho);
        labels(j) = sprintf("Z%d n%d m0", j, n);
    elseif s > 0
        z = sqrt(2 * (n + 1)) * radialZernike(n, m, rho) .* cos(m * theta);
        labels(j) = sprintf("Z%d n%d m%d cos", j, n, m);
    else
        z = sqrt(2 * (n + 1)) * radialZernike(n, m, rho) .* sin(m * theta);
        labels(j) = sprintf("Z%d n%d m%d sin", j, n, m);
    end
    basis(:, j) = z;
end
end

function terms = nollTerms()
terms = [
    0 0 0; 1 1 1; 1 1 -1; 2 0 0; 2 2 -1; 2 2 1; ...
    3 1 -1; 3 1 1; 3 3 -1; 3 3 1; 4 0 0; ...
    4 2 1; 4 2 -1; 4 4 1; 4 4 -1; ...
    5 1 1; 5 1 -1; 5 3 1; 5 3 -1; 5 5 1; 5 5 -1];
end

function r = radialZernike(n, m, rho)
r = zeros(size(rho));
for s = 0:((n - m) / 2)
    c = (-1)^s * factorial(n - s) / ...
        (factorial(s) * factorial((n + m) / 2 - s) * factorial((n - m) / 2 - s));
    r = r + c .* rho.^(n - 2 * s);
end
end

function files = listTiffFiles(folder)
files = dir(fullfile(folder, "*.tif*"));
files = files(~[files.isdir]);
if isempty(files)
    error("No TIFF images were found in %s.", folder);
end
files = sortByFrameNumber(files);
end

function files = sortByFrameNumber(files)
names = string({files.name});
tokens = regexp(names, "\d+", "match");
keys = nan(numel(files), 1);
for k = 1:numel(files)
    if ~isempty(tokens{k})
        keys(k) = str2double(tokens{k}{end});
    end
end
if all(~isnan(keys))
    [~, order] = sort(keys);
else
    [~, order] = sort(names);
end
files = files(order);
end

function frame = extractFrameNumber(path)
[~, name] = fileparts(path);
token = regexp(name, "(\d+)", "tokens", "once");
if isempty(token)
    frame = NaN;
else
    frame = str2double(token{1});
end
end

function value = rmsFinite(values)
values = values(isfinite(values));
value = sqrt(mean(values(:).^2));
end

function ensureDir(path)
if ~exist(path, "dir")
    mkdir(path);
end
end
