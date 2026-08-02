function report = runProbeIf(jsonPath, varargin)
%RUNPROBEIF IF probe before acquisition: time-domain + spectrum PNGs for Web UI.
%
%   report = runProbeIf(jsonPath)
%   report = runProbeIf(jsonPath, 'outDir', dir)
%
% Reads a short IF segment (default 100 ms, same idea as probeData.m), saves:
%   probe_spectrum.png, probe_time.png, probe_hist.png,
%   probe_pb_debug.png (pulse blanker f_mitigate debug, when EnablePB)
% Does NOT run acquisition / tracking / navigation.

    setupPaths();

    p = inputParser;
    addParameter(p, 'outDir', '', @(x) ischar(x) || isstring(x));
    parse(p, varargin{:});

    jsonPath = char(jsonPath);
    if ~isfile(jsonPath)
        error('runProbeIf:Missing', 'Config not found: %s', jsonPath);
    end
    raw = jsondecode(fileread(jsonPath));

    tag = localStr(raw, 'tag', char(string(datetime('now'), 'yyMMdd_HHmmss')));
    outDir = char(p.Results.outDir);
    if isempty(outDir)
        outDir = localStr(raw, 'outDir', '');
    end
    if isempty(outDir)
        root = fileparts(fileparts(mfilename('fullpath')));
        outDir = fullfile(root, 'results', 'ui', ['probe_' tag]);
    end
    if ~exist(outDir, 'dir'), mkdir(outDir); end
    figDir = fullfile(outDir, 'probe');
    if ~exist(figDir, 'dir'), mkdir(figDir); end

    % Build settings (reuse init + nested apply logic subset)
    nv = {};
    for k = {'filePath','fileName','msToProcess','numberOfChannels'}
        if isfield(raw, k{1}), nv{end+1} = k{1}; nv{end+1} = raw.(k{1}); end %#ok<AGROW>
    end
    settings = initSettings(nv{:});
    for k = {'samplingFreq','IF','dataType','fileType','EnablePB','Th_static_dBm'}
        if isfield(raw, k{1}), settings.(k{1}) = raw.(k{1}); end
    end
    if isfield(raw, 'usrp') && isstruct(raw.usrp)
        f = fieldnames(raw.usrp);
        for i = 1:numel(f), settings.usrp.(f{i}) = raw.usrp.(f{i}); end
    end
    if isfield(raw, 'PB_settings') && isstruct(raw.PB_settings)
        f = fieldnames(raw.PB_settings);
        for i = 1:numel(f)
            settings.PB_settings.(f{i}) = raw.PB_settings.(f{i});
        end
    end
    % Recompute static digital threshold if dBm / USRP scale changed
    if isfield(settings, 'Th_static_dBm') && isfield(settings, 'usrp')
        try
            threshold_digdB = settings.Th_static_dBm - settings.usrp.scaleK - ...
                settings.usrp.gain + 10*log10(settings.samplingFreq);
            settings.PB_settings.Th_static = 10.^(threshold_digdB/20);
        catch
        end
    end
    if isfield(raw, 'skipNumberOfBytes') && isfinite(raw.skipNumberOfBytes)
        settings.skipNumberOfBytes = raw.skipNumberOfBytes;
    end

    probeTime = 100e-3; % s, match probeData
    if isfield(raw, 'probeDurationMs') && isfinite(raw.probeDurationMs) ...
            && raw.probeDurationMs > 0
        probeTime = double(raw.probeDurationMs) / 1000;
    end
    ifIQshowInt = min(10e-3, probeTime);

    report = struct();
    report.ok = false;
    report.stage = 'probe';
    report.outDir = outDir;
    report.figDir = figDir;
    report.error = '';
    report.images = struct('spectrum', '', 'time', '', 'hist', '', 'pbDebug', '');

    fileNameStr = fullfile(settings.filePath, settings.fileName);
    fprintf('========== IF Probe ==========\n');
    fprintf('file=%s\n', fileNameStr);
    fprintf('fs=%g IF=%g probe=%.0f ms\n', settings.samplingFreq, settings.IF, probeTime*1e3);

    try
        [fid, message] = fopen(fileNameStr, 'rb');
        if fid <= 0
            error('runProbeIf:Open', 'Unable to read %s: %s', fileNameStr, message);
        end
        cleaner = onCleanup(@() fclose(fid));

        if isfield(settings, 'skipNumberOfBytes') && settings.skipNumberOfBytes > 0
            fseek(fid, settings.skipNumberOfBytes, 'bof');
        end

        samplesPerCode = round(settings.samplingFreq / ...
            (settings.codeFreqBasis / settings.codeLength));
        if settings.fileType == 1
            dataAdaptCoeff = 1;
        else
            dataAdaptCoeff = 2;
        end

        dataNum = max(1, round(dataAdaptCoeff * probeTime * settings.samplingFreq));
        [data, count] = fread(fid, [1, dataNum], settings.dataType);
        if count < min(dataNum, dataAdaptCoeff * samplesPerCode)
            error('runProbeIf:Short', 'Could not read enough IF samples (%d/%d)', count, dataNum);
        end

        % Invisible figures for batch/UI
        set(0, 'DefaultFigureVisible', 'off');

        pathSpec = fullfile(figDir, 'probe_spectrum.png');
        pathTime = fullfile(figDir, 'probe_time.png');
        pathHist = fullfile(figDir, 'probe_hist.png');
        pathPB   = fullfile(figDir, 'probe_pb_debug.png');

        if settings.fileType == 1
            x = double(data);
            zSig = x; % real for PB
            t = (0:numel(x)-1) / settings.samplingFreq * 1e3; % ms

            figT = figure('Color', 'w', 'Position', [50 50 900 360], 'Visible', 'off');
            nShow = min(numel(x), round(settings.samplingFreq * ifIQshowInt));
            plot(t(1:nShow), x(1:nShow), 'Color', [0.12 0.35 0.65], 'LineWidth', 0.6);
            grid on; box on;
            title(sprintf('Time domain (real)  N=%d  show=%.1f ms', numel(x), ifIQshowInt*1e3));
            xlabel('Time (ms)'); ylabel('Amplitude');
            localSaveFig(figT, pathTime); close(figT);

            figF = figure('Color', 'w', 'Position', [50 50 900 360], 'Visible', 'off');
            pwelch(x, 32768, 2048, 32768, settings.samplingFreq/1e6);
            grid on; box on;
            title('Power spectral density (Welch)');
            xlabel('Frequency (MHz)'); ylabel('PSD');
            localSaveFig(figF, pathSpec); close(figF);

            figH = figure('Color', 'w', 'Position', [50 50 900 360], 'Visible', 'off');
            histogram(x, 256, 'FaceColor', [0.25 0.45 0.7], 'EdgeColor', 'none');
            grid on; box on;
            title('Histogram (real)');
            xlabel('Bin'); ylabel('Count');
            localSaveFig(figH, pathHist); close(figH);
        else
            % IQ interleaved
            n = 2 * floor(numel(data) / 2);
            data = data(1:n);
            z = double(data(1:2:end)) + 1i * double(data(2:2:end));
            zSig = z;
            t = (0:numel(z)-1) / settings.samplingFreq * 1e3;

            nShow = min(numel(z), round(settings.samplingFreq * ifIQshowInt));
            figT = figure('Color', 'w', 'Position', [50 50 900 520], 'Visible', 'off');
            subplot(3,1,1);
            plot(t(1:nShow), real(z(1:nShow)), 'Color', [0.12 0.35 0.65], 'LineWidth', 0.5);
            grid on; box on; title('Time domain — I'); ylabel('Amp');
            subplot(3,1,2);
            plot(t(1:nShow), imag(z(1:nShow)), 'Color', [0.75 0.25 0.15], 'LineWidth', 0.5);
            grid on; box on; title('Time domain — Q'); ylabel('Amp');
            subplot(3,1,3);
            plot(t(1:nShow), abs(z(1:nShow)), 'Color', [0.15 0.55 0.35], 'LineWidth', 0.5);
            grid on; box on; title('|IQ|'); xlabel('Time (ms)'); ylabel('Amp');
            sgtitle(sprintf('IF time domain  N=%d  show=%.1f ms  fs=%.3f MHz', ...
                numel(z), ifIQshowInt*1e3, settings.samplingFreq/1e6), 'FontWeight', 'bold');
            localSaveFig(figT, pathTime); close(figT);

            figF = figure('Color', 'w', 'Position', [50 50 900 400], 'Visible', 'off');
            [sigspec, freqv] = pwelch(z, 32768, 2048, 32768, settings.samplingFreq, 'twosided');
            half = floor(numel(freqv)/2);
            fplot = [-(freqv(half:-1:1)); freqv(1:half)] / 1e6;
            pplot = 10*log10([sigspec(half+1:end); sigspec(1:half)]);
            plot(fplot, pplot, 'Color', [0.1 0.3 0.55], 'LineWidth', 0.8);
            grid on; box on;
            title('Power spectral density (two-sided Welch)');
            xlabel('Frequency (MHz)'); ylabel('PSD (dB)');
            localSaveFig(figF, pathSpec); close(figF);

            figH = figure('Color', 'w', 'Position', [50 50 900 400], 'Visible', 'off');
            subplot(1,2,1);
            histogram(real(z), 200, 'FaceColor', [0.25 0.45 0.7], 'EdgeColor', 'none');
            grid on; box on; title('Histogram I'); xlabel('Bin');
            subplot(1,2,2);
            histogram(imag(z), 200, 'FaceColor', [0.75 0.4 0.3], 'EdgeColor', 'none');
            grid on; box on; title('Histogram Q'); xlabel('Bin');
            localSaveFig(figH, pathHist); close(figH);
        end

        % --- PB debug figure (always attempt when EnablePB; uses f_mitigate) ---
        doPB = true;
        if isfield(settings, 'EnablePB')
            doPB = logical(settings.EnablePB);
        end
        % Force debugplot path for probe even if PB_settings.debugplot is false
        if isfield(raw, 'PB_settings') && isfield(raw.PB_settings, 'debugplot')
            if ~raw.PB_settings.debugplot && ~doPB
                doPB = false;
            end
        end
        report.pbEnabled = doPB;
        if doPB
            try
                pb = pulseBlanker(settings);
                kScale = -94.72;
                gScale = 60;
                if isfield(settings, 'usrp')
                    if isfield(settings.usrp, 'scaleK'), kScale = settings.usrp.scaleK; end
                    if isfield(settings.usrp, 'gain'),   gScale = settings.usrp.gain; end
                end
                % f_mitigate returns [signal_post, fig] — make fig invisible
                % Prefer class debug plot (Input / Output / Threshold in dBm)
                try
                    [~, figPB] = pb.f_mitigate(zSig(:).', kScale, gScale, settings.samplingFreq);
                catch
                    % Fallback: manual plot if legend options unsupported
                    figPB = localPbFallbackFig(zSig(:).', pb, kScale, gScale, settings.samplingFreq);
                end
                if ~isempty(figPB) && isgraphics(figPB)
                    set(figPB, 'Visible', 'off', 'Color', 'w');
                    try
                        set(figPB, 'Units', 'pixels', 'Position', [50 50 1000 420]);
                    catch
                    end
                    try
                        ax = get(figPB, 'CurrentAxes');
                        if ~isempty(ax)
                            title(ax, sprintf( ...
                                'Pulse blanker debug  PDC=%.3f%%  UseStatic=%d', ...
                                100*pb.PDC, pb.UseStatic));
                        end
                    catch
                    end
                    localSaveFig(figPB, pathPB);
                    close(figPB);
                    report.images.pbDebug = 'probe/probe_pb_debug.png';
                    report.pbPDC = pb.PDC;
                    fprintf('  PB debug saved (PDC=%.4f)\n', pb.PDC);
                end
            catch ME
                warning('runProbeIf:PB', 'PB debug plot failed: %s', ME.message);
                report.pbError = ME.message;
            end
        else
            fprintf('  PB disabled — skip PB debug figure\n');
        end

        report.ok = true;
        report.stage = 'done';
        report.images.spectrum = 'probe/probe_spectrum.png';
        report.images.time = 'probe/probe_time.png';
        report.images.hist = 'probe/probe_hist.png';
        report.nSamples = count;
        report.probeDurationMs = probeTime * 1e3;
        report.samplingFreq = settings.samplingFreq;
        report.fileType = settings.fileType;
        fprintf('Probe OK -> %s\n', figDir);
    catch ME
        report.ok = false;
        report.error = ME.message;
        report.stage = 'failed';
        fprintf(2, 'Probe FAILED: %s\n', ME.message);
    end

    % report.json
    try
        txt = jsonencode(report);
    catch
        txt = sprintf('{"ok":%d,"error":"%s"}', report.ok, strrep(report.error, '"', ''''));
    end
    fidw = fopen(fullfile(outDir, 'report.json'), 'w', 'n', 'UTF-8');
    if fidw > 0
        fwrite(fidw, txt, 'char');
        fclose(fidw);
    end
end

function s = localStr(raw, name, default)
    s = default;
    if isfield(raw, name) && ~isempty(raw.(name))
        s = char(string(raw.(name)));
    end
end

function localSaveFig(fig, path)
    if exist('exportgraphics', 'file') == 2
        exportgraphics(fig, path, 'Resolution', 150);
    else
        print(fig, path, '-dpng', '-r150');
    end
end

function fig = localPbFallbackFig(signal, pb, k, gain, fs)
%LOCALPBFALLBACKFIG Simple Input/Output/Threshold plot if f_mitigate fails.
    signal = signal(:).';
    th = pb.Th_static;
    if ~pb.UseStatic && pb.EPWR_th > 0
        th = pb.EPWR_th;
    end
    post = signal;
    post(abs(post) > th) = 0;
    scale = k + gain - 10*log10(fs);
    t_axis = (1:numel(signal)) / fs * 1e3;
    pwr_pre  = 10*log10(abs(signal).^2 + 1e-30) + scale;
    pwr_post = 10*log10(abs(post).^2 + 1e-30) + scale;
    thrLine  = 20*log10(th + 1e-30) + scale;
    fig = figure('Color', 'w', 'Visible', 'off', 'Position', [50 50 1000 420]);
    hold on; grid on; box on;
    plot(t_axis, pwr_pre, 'b', 'LineWidth', 0.5);
    plot(t_axis, pwr_post, 'r', 'LineWidth', 0.5);
    plot([t_axis(1) t_axis(end)], [thrLine thrLine], 'k--', 'LineWidth', 1);
    xlabel('T (ms)'); ylabel('Power (dBm)');
    legend({'Input','Output','Threshold'}, 'Location', 'south');
    title(sprintf('Pulse blanker debug (fallback)  blank rate ≈ %.2f%%', ...
        100 * mean(abs(signal) > th)));
end
