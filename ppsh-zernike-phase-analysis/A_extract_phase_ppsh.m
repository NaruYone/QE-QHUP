function A_extract_phase_ppsh()
% # A. Extract wrapped phase
% Convert PPSH/LUCID hologram TIFF images in ./source to wrapped phase TIFFs
% in ./phase. The phase is stored as uint16 mapped from [-pi, pi].

root_dir = fileparts(mfilename("fullpath"));
source_dir = fullfile(root_dir, "source");
phase_dir = fullfile(root_dir, "phase");

ensureDir(phase_dir);
files = listTiffFiles(source_dir);

for k = 1:numel(files)
    src = fullfile(files(k).folder, files(k).name);
    hologram = readFirstChannel(src);

    % PPSH pixel order inherited from the original phase_analysis.m workflow.
    sz = size(hologram);
    I0 = imresize(hologram(2:2:sz(1), 2:2:sz(2)), sz, "bicubic");
    I45 = imresize(hologram(1:2:sz(1), 2:2:sz(2)), sz, "bicubic");
    I90 = imresize(hologram(1:2:sz(1), 1:2:sz(2)), sz, "bicubic");
    I135 = imresize(hologram(2:2:sz(1), 1:2:sz(2)), sz, "bicubic");

    complex_amp = ((I90 - I0) + 1i * (I135 - I45)) / 4;
    phase = angle(complex_amp);

    [~, stem] = fileparts(files(k).name);
    out = fullfile(phase_dir, stem + "_phase.tif");
    writePhaseTiff(phase, out);
    fprintf("Saved %d/%d: %s\n", k, numel(files), out);
end
end

function img = readFirstChannel(path)
img = imread(path);
if ndims(img) == 3
    img = img(:, :, 1);
end
img = double(img);
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
