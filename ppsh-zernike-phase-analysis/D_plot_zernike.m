function D_plot_zernike()
% # D. Plot Zernike coefficients
% Export PNG figures from zernike_coefficients_Z1_to_Z21.csv:
% 1) selected Noll-index mode maps and 2) all-coefficient bar charts.

root_dir = fileparts(mfilename("fullpath"));
zernike_dir = fullfile(root_dir, "phase_16_16", "zernike");
coefficient_csv = fullfile(zernike_dir, "zernike_coefficients_Z1_to_Z21.csv");
output_dir = fullfile(zernike_dir, "plots");

frames = [];          % Example: [30 40 50]. Empty [] uses frame_start:frame_step:frame_end.
frame_start = 30;
frame_end = 80;
frame_step = 10;
selected_noll_indices = [4 11];

output_mode_maps = true;
output_bar_charts = true;

mode_limits = [-1 1];
bar_limits = [-1.5 1.5];
font_size = 36;

settings = loadSettings(zernike_dir);
ensureDir(output_dir);
if ~isfile(coefficient_csv)
    error("Coefficient CSV was not found: %s", coefficient_csv);
end

coefficients = readtable(coefficient_csv);
frames = selectFrames(coefficients, frames, frame_start, frame_end, frame_step);

if output_mode_maps
    [rho, theta, mask] = buildPolarGrid(settings.roi_size);
end

for frame = frames
    frame_table = sortrows(coefficients(frameRows(coefficients, frame), :), "noll_index");
    if isempty(frame_table)
        error("No coefficients were found for frame %g.", frame);
    end

    if output_mode_maps
        saveModeMaps(frame_table, selected_noll_indices, rho, theta, mask, output_dir, mode_limits, font_size);
    end

    if output_bar_charts
        saveBarChart(frame_table, output_dir, bar_limits, font_size);
    end
end

fprintf("Saved Zernike coefficient plots to:\n%s\n", output_dir);
end

function settings = loadSettings(zernike_dir)
settings.roi_size = 1024;
path = fullfile(zernike_dir, "zernike_fit_settings.mat");
if isfile(path)
    s = load(path);
    if isfield(s, "roi_size")
        settings.roi_size = s.roi_size;
    end
end
end

function frames = selectFrames(coefficients, frames, frame_start, frame_end, frame_step)
if ~isempty(frames)
    return;
end
available = unique(coefficients.frame, "stable").';
available = available(~isnan(available));
if isempty(frame_start) && isempty(frame_end)
    frames = available;
else
    frames = frame_start:frame_step:frame_end;
    frames = frames(ismember(frames, available));
end
if isempty(frames)
    error("No frames in the requested range were found in the coefficient CSV.");
end
end

function rows = frameRows(coefficients, frame)
if isnan(frame)
    rows = isnan(coefficients.frame);
else
    rows = coefficients.frame == frame;
end
end

function saveModeMaps(frame_table, selected_indices, rho, theta, mask, output_dir, limits, font_size)
frame = frame_table.frame(1);
for z_index = selected_indices
    rows = frame_table.noll_index == z_index;
    if nnz(rows) ~= 1
        error("Could not find one Z%d coefficient for frame %g.", z_index, frame);
    end

    z_map = nan(size(rho));
    z_basis = buildSingleZernike(rho, theta, z_index);
    z_map(mask) = frame_table.coefficient_rad(rows) * z_basis(mask);

    out = fullfile(output_dir, sprintf("frame%04g_Z%d_distribution.png", frame, z_index));
    saveMap(z_map, mask, limits, out, font_size);
end
end

function saveBarChart(frame_table, output_dir, limits, font_size)
frame = frame_table.frame(1);
fig = figure("Color", "w", "Position", [100 100 1100 620]);
b = bar(frame_table.noll_index, frame_table.coefficient_rad, "FaceColor", "flat");
colors = arrayfun(@zernikeColor, frame_table.noll_index, "UniformOutput", false);
b.CData = vertcat(colors{:});
grid on;
box on;
xlim([0.5, max(frame_table.noll_index) + 0.5]);
xticks(1:2:max(frame_table.noll_index));
if ~isempty(limits)
    ylim(limits);
end
xlabel("Noll Zernike index", "FontSize", font_size);
ylabel("Coefficient [rad]", "FontSize", font_size);
set(gca, "FontSize", font_size, "LineWidth", 1.2, "TickDir", "in");

out = fullfile(output_dir, sprintf("frame%04g_Zernike_coefficients.png", frame));
exportgraphics(fig, out, "Resolution", 200);
close(fig);
fprintf("Saved: %s\n", out);
end

function color = zernikeColor(z_index)
switch z_index
    case 4
        color = [0.9290 0.4940 0.1250];
    case 11
        color = [0.4940 0.1840 0.5560];
    otherwise
        color = [0.55 0.55 0.55];
end
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

function z = buildSingleZernike(rho, theta, noll_index)
terms = nollTerms();
if noll_index < 1 || noll_index > size(terms, 1)
    error("This script defines Zernike terms only from Z1 to Z%d.", size(terms, 1));
end

n = terms(noll_index, 1);
m = terms(noll_index, 2);
s = terms(noll_index, 3);
if m == 0
    z = sqrt(n + 1) * radialZernike(n, 0, rho);
elseif s > 0
    z = sqrt(2 * (n + 1)) * radialZernike(n, m, rho) .* cos(m * theta);
else
    z = sqrt(2 * (n + 1)) * radialZernike(n, m, rho) .* sin(m * theta);
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

function saveMap(values, mask, limits, path, font_size)
values(~mask) = nan;
fig = figure("Color", "w", "Position", [100 100 760 680]);
imagesc(values);
axis image off;
colormap turbo;
if ~isempty(limits)
    clim(limits);
end
cb = colorbar;
cb.FontSize = font_size;
exportgraphics(fig, path, "Resolution", 200);
close(fig);
fprintf("Saved: %s\n", path);
end

function ensureDir(path)
if ~exist(path, "dir")
    mkdir(path);
end
end
