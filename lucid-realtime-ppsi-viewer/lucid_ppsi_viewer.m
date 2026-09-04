function lucid_ppsi_viewer
% Realtime parallel phase-shifting interferometry viewer for TRI050S-P.
% Four interleaved polarization channels are reconstructed as:
% E = ((I90 - I0) + 1i * (I135 - I45)) / 4.

% Resolve paths and fixed camera parameters.
appDir = fileparts(mfilename('fullpath'));
if isempty(appDir)
    appDir = pwd;
end

bridgePath = fullfile(appDir, 'ArenaLatestFrameWriter.exe');
runtimeDir = fullfile(appDir, 'live_frame');
stopRequestPath = fullfile(runtimeDir, 'stop.request');
controlPath = fullfile(runtimeDir, 'camera_control.txt');
pixelFormat = 'PolarizedAngles_0d_45d_90d_135d_Mono8';
sharedMemoryName = 'Local\RealtimePPSI_Frame';
readerAssemblyPath = fullfile(appDir, 'PpsiSharedMemoryReader.dll');
minimumExposureUs = 20;
maximumGainDb = 48;

if ~exist(runtimeDir, 'dir')
    mkdir(runtimeDir);
end

% Keep acquisition resources and runtime counters in one state structure.
state.bridgeProcess = [];
state.frameTimer = [];
state.running = false;
state.lastFrameCount = -1;
state.exposureUs = 4000;
state.gainDb = 0;
state.frameReader = [];
state.displayedFrames = 0;
state.displayStartTic = [];

% Build the three-image viewer and camera control panel.
mainFigure = figure( ...
    'Name', 'LUCID PPSI Viewer', ...
    'NumberTitle', 'off', ...
    'Color', [0.12 0.12 0.12], ...
    'MenuBar', 'none', ...
    'ToolBar', 'none', ...
    'Units', 'normalized', ...
    'Position', [0.06 0.08 0.88 0.82], ...
    'CloseRequestFcn', @onClose);

axHologram = makeImageAxes([0.020 0.13 0.245 0.74]);
axAmplitude = makeImageAxes([0.285 0.13 0.245 0.74]);
axPhase = makeImageAxes([0.550 0.13 0.245 0.74]);

imgHologram = imagesc(axHologram, zeros(2, 2, 'single'));
imgAmplitude = imagesc(axAmplitude, zeros(2, 2, 'single'));
imgPhase = imagesc(axPhase, zeros(2, 2, 'single'));
configureImageAxes(axHologram, gray(256), [0 255]);
configureImageAxes(axAmplitude, gray(256), [0 100]);
configureImageAxes(axPhase, gray(256), [-pi pi]);
setImageTitle(axHologram, 'Captured hologram [I0 I45; I90 I135]');
setImageTitle(axAmplitude, 'Amplitude |E|');
setImageTitle(axPhase, 'Phase arg(E)');

panel = uipanel(mainFigure, ...
    'Title', 'Camera', ...
    'ForegroundColor', [0.95 0.95 0.95], ...
    'BackgroundColor', [0.18 0.18 0.18], ...
    'Units', 'normalized', ...
    'Position', [0.805 0.07 0.175 0.88]);

uicontrol(panel, ...
    'Style', 'text', ...
    'String', {'Pixel format (fixed)', pixelFormat}, ...
    'ForegroundColor', [0.9 0.9 0.9], ...
    'BackgroundColor', [0.18 0.18 0.18], ...
    'HorizontalAlignment', 'left', ...
    'Units', 'normalized', ...
    'Position', [0.07 0.88 0.86 0.08]);

controls.fps = addEdit(panel, 'FPS', '5', 0.81);
set(controls.fps, 'Callback', @onFpsChanged);

controls.exposureValue = uicontrol(panel, ...
    'Style', 'text', ...
    'String', 'Exposure: 4000 us', ...
    'ForegroundColor', [0.9 0.9 0.9], ...
    'BackgroundColor', [0.18 0.18 0.18], ...
    'HorizontalAlignment', 'left', ...
    'Units', 'normalized', ...
    'Position', [0.08 0.735 0.84 0.04]);
controls.exposure = uicontrol(panel, ...
    'Style', 'slider', ...
    'Min', 0, ...
    'Max', 1, ...
    'Value', exposureToSlider(state.exposureUs, 5), ...
    'SliderStep', [0.005 0.05], ...
    'Units', 'normalized', ...
    'Position', [0.08 0.69 0.84 0.04], ...
    'Callback', @onExposureChanged);

controls.gainValue = uicontrol(panel, ...
    'Style', 'text', ...
    'String', 'Gain: 0.0 dB', ...
    'ForegroundColor', [0.9 0.9 0.9], ...
    'BackgroundColor', [0.18 0.18 0.18], ...
    'HorizontalAlignment', 'left', ...
    'Units', 'normalized', ...
    'Position', [0.08 0.625 0.84 0.04]);
controls.gain = uicontrol(panel, ...
    'Style', 'slider', ...
    'Min', 0, ...
    'Max', maximumGainDb, ...
    'Value', state.gainDb, ...
    'SliderStep', [0.01 0.10], ...
    'Units', 'normalized', ...
    'Position', [0.08 0.58 0.84 0.04], ...
    'Callback', @onGainChanged);

controls.width = addEdit(panel, 'ROI width', '2448', 0.50);
controls.height = addEdit(panel, 'ROI height', '2048', 0.43);
controls.centerX = addEdit(panel, 'Center X', '1224', 0.36);
controls.centerY = addEdit(panel, 'Center Y', '1024', 0.29);

controls.start = uicontrol(panel, ...
    'Style', 'pushbutton', ...
    'String', 'Start', ...
    'FontWeight', 'bold', ...
    'Units', 'normalized', ...
    'Position', [0.08 0.21 0.39 0.055], ...
    'Callback', @onStart);

controls.stop = uicontrol(panel, ...
    'Style', 'pushbutton', ...
    'String', 'Stop', ...
    'Units', 'normalized', ...
    'Position', [0.53 0.21 0.39 0.055], ...
    'Enable', 'off', ...
    'Callback', @onStop);

controls.status = uicontrol(panel, ...
    'Style', 'text', ...
    'String', 'Ready', ...
    'ForegroundColor', [0.9 0.9 0.9], ...
    'BackgroundColor', [0.12 0.12 0.12], ...
    'HorizontalAlignment', 'left', ...
    'Units', 'normalized', ...
    'Position', [0.07 0.025 0.86 0.16]);

controls.hologramMax = addRangeControl( ...
    'Hologram max', '255', 0.020, @onHologramRangeChanged);
controls.amplitudeMax = addRangeControl( ...
    'Amplitude max', '100', 0.285, @onAmplitudeRangeChanged);
controls.phaseMagnitude = addRangeControl( ...
    'Phase +/-', sprintf('%.6f', pi), 0.550, @onPhaseRangeChanged);

    % GUI construction helpers.
    function ax = makeImageAxes(position)
        ax = axes(mainFigure, ...
            'Units', 'normalized', ...
            'Position', position, ...
            'Color', [0 0 0]);
    end

    function setImageTitle(ax, label)
        title(ax, label, ...
            'Color', [0.95 0.95 0.95], ...
            'FontWeight', 'bold', ...
            'FontSize', 14);
    end

    function configureImageAxes(ax, colorMap, limits)
        axis(ax, 'image');
        axis(ax, 'off');
        colormap(ax, colorMap);
        if isempty(limits)
            set(ax, 'CLimMode', 'auto');
        else
            clim(ax, limits);
        end
    end

    function editHandle = addEdit(parent, label, value, y)
        uicontrol(parent, ...
            'Style', 'text', ...
            'String', label, ...
            'ForegroundColor', [0.9 0.9 0.9], ...
            'BackgroundColor', [0.18 0.18 0.18], ...
            'HorizontalAlignment', 'left', ...
            'Units', 'normalized', ...
            'Position', [0.08 y 0.48 0.045]);
        editHandle = uicontrol(parent, ...
            'Style', 'edit', ...
            'String', value, ...
            'BackgroundColor', [1 1 1], ...
            'Units', 'normalized', ...
            'Position', [0.57 y 0.35 0.05]);
    end

    function editHandle = addRangeControl(label, value, x, callback)
        uicontrol(mainFigure, ...
            'Style', 'text', ...
            'String', label, ...
            'FontWeight', 'bold', ...
            'ForegroundColor', [0.95 0.95 0.95], ...
            'BackgroundColor', [0.12 0.12 0.12], ...
            'HorizontalAlignment', 'right', ...
            'Units', 'normalized', ...
            'Position', [x 0.055 0.105 0.035]);
        editHandle = uicontrol(mainFigure, ...
            'Style', 'edit', ...
            'String', value, ...
            'BackgroundColor', [1 1 1], ...
            'Units', 'normalized', ...
            'Position', [x + 0.110 0.052 0.070 0.042]);
        uicontrol(mainFigure, ...
            'Style', 'pushbutton', ...
            'String', 'Apply', ...
            'FontWeight', 'bold', ...
            'Units', 'normalized', ...
            'Position', [x + 0.185 0.052 0.055 0.042], ...
            'Callback', callback);
    end

    % Display-range callbacks affect visualization only, not source data.
    function onAmplitudeRangeChanged(~, ~)
        value = readPositiveRange(controls.amplitudeMax, 'Amplitude');
        if isempty(value)
            return;
        end
        clim(axAmplitude, [0 value]);
        setStatus(sprintf('Amplitude display range: 0 to %.4g', value));
    end

    function onPhaseRangeChanged(~, ~)
        value = readPositiveRange(controls.phaseMagnitude, 'Phase');
        if isempty(value)
            return;
        end
        clim(axPhase, [-value value]);
        setStatus(sprintf('Phase display range: +/- %.4f rad', value));
    end

    function onHologramRangeChanged(~, ~)
        value = readPositiveRange(controls.hologramMax, 'Hologram');
        if isempty(value)
            return;
        end
        clim(axHologram, [0 value]);
        setStatus(sprintf('Hologram display range: 0 to %.4g', value));
    end

    function value = readPositiveRange(editHandle, name)
        value = str2double(get(editHandle, 'String'));
        if ~isfinite(value) || value <= 0
            setStatus([name ' range must be a positive finite number.']);
            value = [];
        end
    end

    function maxUs = maximumExposureUs(fps)
        maxUs = max(minimumExposureUs * 1.001, 1000000 / fps);
    end

    function sliderValue = exposureToSlider(exposureUs, fps)
        maxUs = maximumExposureUs(fps);
        exposureUs = max(minimumExposureUs, min(maxUs, exposureUs));
        sliderValue = log(exposureUs / minimumExposureUs) / ...
            log(maxUs / minimumExposureUs);
        sliderValue = max(0, min(1, sliderValue));
    end

    function exposureUs = sliderToExposure(sliderValue, fps)
        maxUs = maximumExposureUs(fps);
        exposureUs = minimumExposureUs * ...
            (maxUs / minimumExposureUs) ^ sliderValue;
        exposureUs = min(exposureUs, 1000000 / fps);
    end

    % Send exposure, gain, and frame-rate changes to the camera bridge.
    function onExposureChanged(~, ~)
        fps = validFps();
        if isempty(fps)
            return;
        end
        state.exposureUs = sliderToExposure(get(controls.exposure, 'Value'), fps);
        updateExposureLabel(fps);
        writeControlFile();
    end

    function onGainChanged(~, ~)
        state.gainDb = get(controls.gain, 'Value');
        set(controls.gainValue, 'String', sprintf('Gain: %.1f dB', state.gainDb));
        writeControlFile();
    end

    function onFpsChanged(~, ~)
        fps = validFps();
        if isempty(fps)
            return;
        end
        state.exposureUs = min(state.exposureUs, 1000000 / fps);
        set(controls.exposure, 'Value', exposureToSlider(state.exposureUs, fps));
        updateExposureLabel(fps);
    end

    function fps = validFps()
        fps = str2double(get(controls.fps, 'String'));
        if ~isfinite(fps) || fps <= 0
            setStatus('FPS must be a positive number.');
            fps = [];
        end
    end

    function updateExposureLabel(fps)
        maxUs = 1000000 / fps;
        set(controls.exposureValue, 'String', sprintf( ...
            'Exposure: %.0f us (max %.0f)', state.exposureUs, maxUs));
    end

    function writeControlFile()
        if ~state.running
            return;
        end
        tmpPath = [controlPath '.tmp'];
        fid = fopen(tmpPath, 'w');
        if fid < 0
            return;
        end
        fprintf(fid, 'exposureUs=%.9g\n', state.exposureUs);
        fprintf(fid, 'gain=%.9g\n', state.gainDb);
        fclose(fid);
        movefile(tmpPath, controlPath, 'f');
    end

    % Start the ArenaNET bridge and the shared-memory display timer.
    function onStart(~, ~)
        if state.running
            return;
        end
        if ~exist(bridgePath, 'file')
            setStatus('ArenaLatestFrameWriter.exe is missing.');
            return;
        end
        if ~exist(readerAssemblyPath, 'file')
            setStatus('PpsiSharedMemoryReader.dll is missing.');
            return;
        end

        values = readSettings();
        if isempty(values)
            return;
        end

        closeSharedMemory();
        deleteIfExists(fullfile(runtimeDir, 'latest_status.txt'));
        deleteIfExists(stopRequestPath);
        deleteIfExists(controlPath);

        args = sprintf([ ...
            '--outdir "%s" --stopfile "%s" --controlfile "%s" --sharedmemory "%s" --pixel %s ' ...
            '--exposure %.9g --gain %.9g --fps %.9g --width %d --height %d ' ...
            '--centerx %d --centery %d'], ...
            runtimeDir, stopRequestPath, controlPath, sharedMemoryName, pixelFormat, ...
            values.exposure, values.gain, values.fps, values.width, values.height, ...
            values.centerX, values.centerY);

        try
            NET.addAssembly('System');
            psi = System.Diagnostics.ProcessStartInfo(char(bridgePath));
            psi.Arguments = char(args);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = appDir;
            state.bridgeProcess = System.Diagnostics.Process.Start(psi);

            state.running = true;
            writeControlFile();
            state.lastFrameCount = -1;
            state.displayedFrames = 0;
            state.displayStartTic = tic;
            state.frameTimer = timer( ...
                'ExecutionMode', 'fixedSpacing', ...
                'BusyMode', 'drop', ...
                'Period', 0.02, ...
                'TimerFcn', @onTimer);
            start(state.frameTimer);

            set(controls.start, 'Enable', 'off');
            set(controls.stop, 'Enable', 'on');
            set([controls.fps controls.width controls.height ...
                controls.centerX controls.centerY], 'Enable', 'off');
            setStatus('Starting camera...');
        catch ME
            stopStreaming();
            setStatus(['Start error: ' ME.message]);
        end
    end

    function values = readSettings()
        values.fps = validFps();
        if isempty(values.fps)
            values = [];
            return;
        end
        values.exposure = min(state.exposureUs, 1000000 / values.fps);
        state.exposureUs = values.exposure;
        values.gain = state.gainDb;
        values.width = round(str2double(get(controls.width, 'String')));
        values.height = round(str2double(get(controls.height, 'String')));
        values.centerX = round(str2double(get(controls.centerX, 'String')));
        values.centerY = round(str2double(get(controls.centerY, 'String')));

        numbers = [values.exposure values.gain values.fps values.width values.height ...
            values.centerX values.centerY];
        if any(~isfinite(numbers)) || values.exposure <= 0 || ...
                values.width <= 0 || values.height <= 0
            setStatus('Camera settings must be finite positive numbers.');
            values = [];
        end
    end

    % Stop acquisition and release bridge and shared-memory resources.
    function onStop(~, ~)
        stopStreaming();
        setStatus('Stopped');
    end

    function stopStreaming()
        if ~isempty(state.frameTimer) && isvalid(state.frameTimer)
            stop(state.frameTimer);
            delete(state.frameTimer);
        end
        state.frameTimer = [];

        if ~isempty(state.bridgeProcess)
            try
                if ~state.bridgeProcess.HasExited
                    requestStop();
                    if ~state.bridgeProcess.WaitForExit(3000)
                        state.bridgeProcess.Kill();
                        state.bridgeProcess.WaitForExit(1000);
                    end
                end
            catch
            end
        end
        state.bridgeProcess = [];
        closeSharedMemory();
        state.running = false;
        deleteIfExists(stopRequestPath);
        deleteIfExists(controlPath);

        if isgraphics(controls.start)
            set(controls.start, 'Enable', 'on');
            set(controls.stop, 'Enable', 'off');
            set([controls.fps controls.width controls.height ...
                controls.centerX controls.centerY], 'Enable', 'on');
        end
    end

    function requestStop()
        fid = fopen(stopRequestPath, 'w');
        if fid >= 0
            fwrite(fid, 'stop');
            fclose(fid);
        end
    end

    % Read the newest frame, reconstruct the complex field, and refresh the GUI.
    function onTimer(~, ~)
        if ~state.running
            return;
        end
        if ~isempty(state.bridgeProcess) && state.bridgeProcess.HasExited
            statusText = readStatusFile();
            stopStreaming();
            setStatus(['Camera process exited. ' statusText]);
            return;
        end

        try
            frame = readSharedFrame();
            if isempty(frame) || frame.frameCount == state.lastFrameCount
                return;
            end

            width = frame.width;
            height = frame.height;
            if frame.bytesPerPixel ~= 4
                setStatus('Unexpected frame metadata; expected 4 bytes/pixel.');
                return;
            end

            expectedBytes = width * height * 4;
            data = frame.data;
            if numel(data) ~= expectedBytes
                return;
            end

            % The bridge stores I0, I45, I90, and I135 for every output pixel.
            packed = reshape(data, 4, width, height);
            i0 = single(reshape(packed(1, :, :), width, height).');
            i45 = single(reshape(packed(2, :, :), width, height).');
            i90 = single(reshape(packed(3, :, :), width, height).');
            i135 = single(reshape(packed(4, :, :), width, height).');

            % Four-step parallel phase-shifting reconstruction.
            realPart = (i90 - i0) / 4;
            imagPart = (i135 - i45) / 4;
            complexField = complex(realPart, imagPart);
            amplitude = abs(complexField);
            phase = angle(complexField);
            capturedHologram = [i0 i45; i90 i135];

            % Update image data without recreating graphics objects.
            set(imgHologram, 'CData', capturedHologram, ...
                'XData', [1 2 * width], 'YData', [1 2 * height]);
            set(imgAmplitude, 'CData', amplitude, ...
                'XData', [1 width], 'YData', [1 height]);
            set(imgPhase, 'CData', phase, ...
                'XData', [1 width], 'YData', [1 height]);

            state.lastFrameCount = frame.frameCount;
            state.displayedFrames = state.displayedFrames + 1;
            displayFps = state.displayedFrames / max(0.001, toc(state.displayStartTic));
            setStatus(sprintf([ ...
                'Streaming | %d x %d | Frame %d\n' ...
                'Camera FPS %.2f | Acquisition FPS %.2f | Display FPS %.2f\n' ...
                'Incomplete %d | Shared memory\n' ...
                'Exposure %.0f / %.0f us (actual / requested)\n' ...
                'Gain %.1f / %.1f dB (actual / requested)'], ...
                width, height, frame.frameCount, frame.cameraFps, ...
                frame.acquisitionFps, displayFps, ...
                frame.dropped, frame.exposureUs, state.exposureUs, ...
                frame.gain, state.gainDb));
            drawnow nocallbacks;
        catch ME
            setStatus(['Display error: ' ME.message]);
        end
    end

    % Convert the latest shared-memory packet to a MATLAB structure.
    function frame = readSharedFrame()
        frame = [];
        if isempty(state.frameReader)
            try
                NET.addAssembly(readerAssemblyPath);
                state.frameReader = PpsiSharedMemory.Reader(sharedMemoryName);
            catch
                closeSharedMemory();
                return;
            end
        end
        packet = state.frameReader.ReadLatest(int64(state.lastFrameCount));
        if isempty(packet)
            return;
        end
        frame.width = double(packet.Width);
        frame.height = double(packet.Height);
        frame.bytesPerPixel = double(packet.BytesPerPixel);
        frame.frameCount = double(packet.FrameCount);
        frame.dropped = double(packet.Dropped);
        frame.exposureUs = packet.ExposureUs;
        frame.gain = packet.Gain;
        frame.cameraFps = packet.CameraFps;
        frame.acquisitionFps = packet.AcquisitionFps;
        frame.data = reshape(uint8(packet.Data), [], 1);
    end

    function closeSharedMemory()
        if ~isempty(state.frameReader)
            try
                state.frameReader.Dispose();
            catch
            end
        end
        state.frameReader = [];
    end

    % Status and cleanup helpers.
    function text = readStatusFile()
        path = fullfile(runtimeDir, 'latest_status.txt');
        if exist(path, 'file')
            text = strtrim(fileread(path));
        else
            text = 'No status file.';
        end
    end

    function setStatus(text)
        if isgraphics(controls.status)
            set(controls.status, 'String', text);
            drawnow limitrate;
        end
    end

    function deleteIfExists(path)
        if exist(path, 'file')
            delete(path);
        end
    end

    function onClose(~, ~)
        stopStreaming();
        if isgraphics(mainFigure)
            delete(mainFigure);
        end
    end
end
