function B_smooth_phase()
% # B. Smooth wrapped phase
% Smooth ./phase using an M x M kernel on the unit complex field exp(i*phase).
% This avoids direct averaging across the -pi/pi wrapping boundary.

root_dir = fileparts(mfilename("fullpath"));
input_dir = fullfile(root_dir, "phase");
M = 16;
output_dir = fullfile(root_dir, sprintf("phase_%d_%d", M, M));

ensureDir(output_dir);
files = listTiffFiles(input_dir);

for k = 1:numel(files)
    src = fullfile(files(k).folder, files(k).name);
    phase = readPhaseTiff(src);
    smoothed = angle(smoothComplex(exp(1i * phase), M));

    [~, stem] = fileparts(files(k).name);
    stem = erase(string(stem), "_phase");
    out = fullfile(output_dir, sprintf("%s_phase_%d_%d.tif", stem, M, M));
    writePhaseTiff(smoothed, out);
    fprintf("Saved %d/%d: %s\n", k, numel(files), out);
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

function out = smoothComplex(img, M)
kernel = ones(M, M, "double") / (M * M);
out = conv2(real(img), kernel, "same") + 1i * conv2(imag(img), kernel, "same");
end

function files = listTiffFiles(folder)
files = dir(fullfile(folder, "*.tif*"));
files = files(~[files.isdir]);
if isempty(files)
    error("No phase TIFF images were found in %s.", folder);
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

function writePhaseTiff(phase, path)
scaled = (double(phase) + pi) / (2 * pi);
scaled = min(max(scaled, 0), 1);
imwrite(uint16(round(scaled * 65535)), path, "tiff", "Compression", "none");
end

function ensureDir(path)
if ~exist(path, "dir")
    mkdir(path);
end
end
