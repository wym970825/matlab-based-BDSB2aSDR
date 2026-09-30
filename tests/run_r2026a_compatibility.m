function report = run_r2026a_compatibility(outputRoot)
%RUN_R2026A_COMPATIBILITY Exercise B2a MEX and UI paths on MATLAB R2026a.
%
%   report = run_r2026a_compatibility()
%   report = run_r2026a_compatibility(outputRoot)
%
% The test is deliberately non-destructive.  Every generated MEX binary,
% synthetic IF sample, figure, log, and JSON report is written below a new
% results/compat_r2026a/<timestamp> directory (or a caller-supplied path
% that must not already exist).  Existing project MEX files and receiver
% data are only read.

    rootDir = fileparts(fileparts(mfilename('fullpath')));
    setupPaths();

    if nargin < 1 || strlength(string(outputRoot)) == 0
        stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss_SSS'));
        outputRoot = fullfile(rootDir, 'results', 'compat_r2026a', stamp);
    end
    outputRoot = char(outputRoot);
    if isfolder(outputRoot) || isfile(outputRoot)
        error('run_r2026a_compatibility:OutputExists', ...
            'Refusing to reuse existing output path: %s', outputRoot);
    end
    mkdir(outputRoot);

    oldFigureVisibility = get(groot, 'DefaultFigureVisible');
    visibilityCleanup = onCleanup(@() set(groot, ...
        'DefaultFigureVisible', oldFigureVisibility));
    set(groot, 'DefaultFigureVisible', 'off');

    report = struct();
    report.ok = false;
    report.outputRoot = outputRoot;
    report.startedAt = char(datetime('now', 'Format', ...
        'yyyy-MM-dd''T''HH:mm:ss.SSSXXX'));
    report.environment = localEnvironment();
    report.failures = {};

    try
        report.prebuiltMex = localTestPrebuiltMex(rootDir);
    catch ME
        report.prebuiltMex = localErrorStruct(ME);
        report.failures{end + 1} = ['prebuiltMex: ' ME.message];
    end

    mexSandbox = fullfile(outputRoot, 'mex_sandbox', 'mex');
    try
        [report.mexBuild, mexSandbox] = localBuildMexSandbox( ...
            rootDir, mexSandbox);
    catch ME
        report.mexBuild = localErrorStruct(ME);
        report.failures{end + 1} = ['mexBuild: ' ME.message];
    end

    if isfield(report.mexBuild, 'ok') && report.mexBuild.ok
        try
            [report.mexNumerics, report.mexPerformance] = ...
                localTestCompiledMex(mexSandbox);
        catch ME
            report.mexNumerics = localErrorStruct(ME);
            report.mexPerformance = struct('ok', false, 'skipped', true);
            report.failures{end + 1} = ['mexNumerics: ' ME.message];
        end
    else
        report.mexNumerics = struct('ok', false, 'skipped', true);
        report.mexPerformance = struct('ok', false, 'skipped', true);
    end

    try
        report.graphics = localTestGraphics(outputRoot);
    catch ME
        report.graphics = localErrorStruct(ME);
        report.failures{end + 1} = ['graphics: ' ME.message];
    end

    try
        report.projectProbe = localTestProjectProbe(rootDir, outputRoot);
        if ~report.projectProbe.ok
            report.failures{end + 1} = ...
                ['projectProbe: ' report.projectProbe.error];
        end
    catch ME
        report.projectProbe = localErrorStruct(ME);
        report.failures{end + 1} = ['projectProbe: ' ME.message];
    end

    report.finishedAt = char(datetime('now', 'Format', ...
        'yyyy-MM-dd''T''HH:mm:ss.SSSXXX'));
    report.ok = isempty(report.failures) && ...
        localSectionOk(report, 'prebuiltMex') && ...
        localSectionOk(report, 'mexBuild') && ...
        localSectionOk(report, 'mexNumerics') && ...
        localSectionOk(report, 'graphics') && ...
        localSectionOk(report, 'projectProbe');

    reportPath = fullfile(outputRoot, 'compatibility_report.json');
    localWriteJson(reportPath, report);
    fprintf('R2026a compatibility report: %s\n', reportPath);
    fprintf('R2026a compatibility overall: %s\n', ...
        string(report.ok));
end

function environment = localEnvironment()
    environment = struct();
    environment.matlabRoot = matlabroot;
    environment.release = version('-release');
    environment.version = version;
    environment.arch = computer('arch');
    environment.mexExtension = mexext;
    environment.javaAvailable = usejava('jvm');
    environment.desktopAvailable = usejava('desktop');
    environment.mcpToolbox = which('shareMATLABSession');

    compiler = mex.getCompilerConfigurations('C', 'Selected');
    if isempty(compiler)
        environment.cCompiler = '';
        environment.cCompilerVersion = '';
        environment.cCompilerLocation = '';
    else
        environment.cCompiler = compiler(1).Name;
        environment.cCompilerVersion = compiler(1).Version;
        environment.cCompilerLocation = compiler(1).Location;
    end
end

function result = localTestPrebuiltMex(rootDir)
    projectMexDir = fullfile(rootDir, 'mex');
    addpath(projectMexDir, '-begin');
    rehash;
    clear pulseBlank_core_mex correlateB2aMs_mex

    result = struct();
    result.pulseBlankPath = which('pulseBlank_core_mex');
    result.correlatorPath = which('correlateB2aMs_mex');
    result.pulseBlankExists = exist('pulseBlank_core_mex', 'file') == 3;
    result.correlatorExists = exist('correlateB2aMs_mex', 'file') == 3;

    x = complex([1, 3, -2, 0.5], [0, 4, 0, -0.5]);
    threshold = 2.5;
    [actual, ppre, ppost, eta] = pulseBlank_core_mex(x, threshold);
    expected = x;
    expected(abs(expected) > threshold) = 0;
    result.pulseBlankExact = isequal(actual, expected);
    result.pulseBlankMetricsFinite = all(isfinite([ppre, ppost, eta]));
    result.ok = result.pulseBlankExists && result.correlatorExists && ...
        result.pulseBlankExact && result.pulseBlankMetricsFinite;
    assert(result.ok, 'Prebuilt R2024b-era MEX binaries did not load cleanly.');
end

function [result, mexSandbox] = localBuildMexSandbox(rootDir, mexSandbox)
    mkdir(mexSandbox);
    sourceMexDir = fullfile(rootDir, 'mex');
    names = {'build_mex.m', 'correlateB2aMs_mex.c', ...
        'pulseBlank_core_mex.c'};
    for idx = 1:numel(names)
        copyfile(fullfile(sourceMexDir, names{idx}), ...
            fullfile(mexSandbox, names{idx}));
    end

    addpath(mexSandbox, '-begin');
    pathCleanup = onCleanup(@() rmpath(mexSandbox));
    clear build_mex correlateB2aMs_mex pulseBlank_core_mex
    rehash;
    buildLog = evalc('build_mex;');
    rehash;

    correlatorPath = fullfile(mexSandbox, ...
        ['correlateB2aMs_mex.' mexext]);
    pulseBlankPath = fullfile(mexSandbox, ...
        ['pulseBlank_core_mex.' mexext]);
    result = struct();
    result.ok = isfile(correlatorPath) && isfile(pulseBlankPath);
    result.outputDirectory = mexSandbox;
    result.correlatorPath = correlatorPath;
    result.pulseBlankPath = pulseBlankPath;
    result.log = buildLog;
    assert(result.ok, 'Sandbox MEX build did not produce both binaries.');
end

function [numerics, performance] = localTestCompiledMex(mexSandbox)
    addpath(mexSandbox, '-begin');
    cleanup = onCleanup(@() rmpath(mexSandbox));
    clear correlateB2aMs_mex pulseBlank_core_mex
    rehash;

    rng(260609, 'twister');
    fs = 20e6;
    codeFrequency = 10.23e6;
    carrierFrequency = 2.125e6;
    codeLength = 10230;
    earlyLateSpacing = 0.5;
    remCode = 0.37;
    remCarrier = 0.123;
    nh = -1;
    blockSize = ceil((codeLength - remCode) / (codeFrequency / fs));
    raw = complex(randn(1, blockSize + 4), randn(1, blockSize + 4));
    codeData = 2 * (rand(1, codeLength + 2) > 0.5) - 1;
    codePilot = 2 * (rand(1, codeLength + 2) > 0.5) - 1;

    [actual, actualCode, actualCarrier] = correlateB2aMs_mex( ...
        raw, codeData, codePilot, remCode, remCarrier, codeFrequency, ...
        carrierFrequency, fs, codeLength, earlyLateSpacing, nh);
    [expected, expectedCode, expectedCarrier] = localCorrelatorReference( ...
        raw, codeData, codePilot, remCode, remCarrier, codeFrequency, ...
        carrierFrequency, fs, codeLength, earlyLateSpacing, nh);

    corrAbsError = max(abs(actual - expected));
    corrNormalizedError = corrAbsError / max(1, sum(abs(raw(1:blockSize))));
    codePhaseError = abs(actualCode - expectedCode);
    carrierPhaseError = abs(angle(exp(1i * ...
        (actualCarrier - expectedCarrier))));

    numerics = struct();
    numerics.ok = corrNormalizedError < 5e-3 && ...
        codePhaseError < 1e-10 && carrierPhaseError < 1e-4;
    numerics.correlationMaxAbsoluteError = corrAbsError;
    numerics.correlationNormalizedError = corrNormalizedError;
    numerics.codePhaseError = codePhaseError;
    numerics.carrierPhaseErrorRad = carrierPhaseError;
    assert(numerics.ok, 'Newly compiled correlator MEX failed tolerance.');

    % Warm up both paths, then report per-call timing without imposing a
    % brittle speedup assertion on a busy developer workstation.
    warmupResult = correlateB2aMs_mex(raw, codeData, codePilot, remCode, remCarrier, ...
        codeFrequency, carrierFrequency, fs, codeLength, ...
        earlyLateSpacing, nh);
    assert(~isempty(warmupResult));
    localCorrelatorReference(raw, codeData, codePilot, remCode, ...
        remCarrier, codeFrequency, carrierFrequency, fs, codeLength, ...
        earlyLateSpacing, nh);
    nMex = 50;
    tic;
    for idx = 1:nMex
        timedResult = correlateB2aMs_mex(raw, codeData, codePilot, remCode, ...
            remCarrier, codeFrequency, carrierFrequency, fs, ...
            codeLength, earlyLateSpacing, nh);
    end
    mexSeconds = toc / nMex;
    assert(~isempty(timedResult));
    nMatlab = 10;
    tic;
    for idx = 1:nMatlab
        localCorrelatorReference(raw, codeData, codePilot, remCode, ...
            remCarrier, codeFrequency, carrierFrequency, fs, ...
            codeLength, earlyLateSpacing, nh);
    end
    matlabSeconds = toc / nMatlab;
    performance = struct('ok', true, ...
        'mexSecondsPerCall', mexSeconds, ...
        'matlabSecondsPerCall', matlabSeconds, ...
        'speedup', matlabSeconds / mexSeconds);
end

function [corr, remCodeOut, remCarrierOut] = localCorrelatorReference( ...
        raw, codeData, codePilot, remCode, remCarrier, codeFrequency, ...
        carrierFrequency, fs, codeLength, earlyLateSpacing, nh)
    step = codeFrequency / fs;
    blockSize = min(numel(raw), ceil((codeLength - remCode) / step));
    t = remCode + (0:blockSize - 1) * step;
    indexEarly = min(numel(codeData), max(1, ...
        ceil(t - earlyLateSpacing) + 1));
    indexPrompt = min(numel(codeData), max(1, ceil(t) + 1));
    indexLate = min(numel(codeData), max(1, ...
        ceil(t + earlyLateSpacing) + 1));

    phase = remCarrier + (0:blockSize - 1) * ...
        (2 * pi * carrierFrequency / fs);
    baseband = raw(1:blockSize) .* exp(1i * phase);
    ibb = imag(baseband);
    qbb = real(baseband);
    dataEarly = codeData(indexEarly);
    dataPrompt = codeData(indexPrompt);
    dataLate = codeData(indexLate);
    pilotEarly = nh * codePilot(indexEarly);
    pilotPrompt = nh * codePilot(indexPrompt);
    pilotLate = nh * codePilot(indexLate);
    corr = [sum(dataEarly .* ibb), sum(dataEarly .* qbb), ...
        sum(dataPrompt .* ibb), sum(dataPrompt .* qbb), ...
        sum(dataLate .* ibb), sum(dataLate .* qbb), ...
        sum(pilotEarly .* ibb), sum(pilotEarly .* qbb), ...
        sum(pilotPrompt .* ibb), sum(pilotPrompt .* qbb), ...
        sum(pilotLate .* ibb), sum(pilotLate .* qbb)];
    remCodeOut = remCode + blockSize * step - codeLength;
    remCarrierOut = rem(remCarrier + blockSize * ...
        (2 * pi * carrierFrequency / fs), 2 * pi);
end

function result = localTestGraphics(outputRoot)
    graphicsDir = fullfile(outputRoot, 'graphics');
    mkdir(graphicsDir);
    result = struct('ok', false, 'classicFigure', '', 'uiFigure', '', ...
        'classicBytes', 0, 'uiBytes', 0);

    classicPath = fullfile(graphicsDir, 'classic_figure.png');
    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [50, 50, 900, 420]);
    classicCleanup = onCleanup(@() localCloseGraphics(fig));
    layout = tiledlayout(fig, 1, 2, 'TileSpacing', 'compact');
    ax1 = nexttile(layout);
    plot(ax1, 0:0.01:1, sin(2 * pi * (0:0.01:1)), 'LineWidth', 1.2);
    title(ax1, 'R2026a classic figure');
    grid(ax1, 'on');
    ax2 = nexttile(layout);
    imagesc(ax2, peaks(64));
    axis(ax2, 'image');
    title(ax2, 'Layout and colormap');
    exportgraphics(fig, classicPath, 'Resolution', 120);
    close(fig);

    uiPath = fullfile(graphicsDir, 'ui_figure.png');
    ui = uifigure('Visible', 'off', 'Name', 'B2a R2026a UI check', ...
        'Position', [80, 80, 760, 420]);
    uiCleanup = onCleanup(@() localCloseGraphics(ui));
    gridLayout = uigridlayout(ui, [2, 2]);
    gridLayout.RowHeight = {36, '1x'};
    label = uilabel(gridLayout, 'Text', 'BDS B2a — R2026a UI compatibility');
    label.Layout.Row = 1;
    label.Layout.Column = [1, 2];
    axesUi = uiaxes(gridLayout);
    axesUi.Layout.Row = 2;
    axesUi.Layout.Column = [1, 2];
    plot(axesUi, 0:0.01:1, cos(4 * pi * (0:0.01:1)), ...
        'LineWidth', 1.2);
    grid(axesUi, 'on');
    title(axesUi, 'UIFigure / UIAxes rendering');
    drawnow;
    % R2026a renders web-backed UI components asynchronously.  In a
    % no-desktop MCP session, exportapp can otherwise capture the loading
    % spinner instead of the completed axes.
    pause(5);
    drawnow;
    exportapp(ui, uiPath);
    close(ui);

    classicInfo = dir(classicPath);
    uiInfo = dir(uiPath);
    result.classicFigure = classicPath;
    result.uiFigure = uiPath;
    result.classicBytes = classicInfo.bytes;
    result.uiBytes = uiInfo.bytes;
    result.ok = result.classicBytes > 1000 && result.uiBytes > 10000;
    assert(result.ok, 'Classic figure or UIFigure export was empty.');
end

function result = localTestProjectProbe(rootDir, outputRoot)
    syntheticDir = fullfile(outputRoot, 'synthetic_if');
    probeDir = fullfile(outputRoot, 'project_probe');
    mkdir(syntheticDir);
    fs = 1e6;
    sampleCount = 100000;
    rng(260610, 'twister');
    time = (0:sampleCount - 1) / fs;
    signal = 1800 * exp(1i * 2 * pi * 0.08e6 * time) + ...
        180 * complex(randn(1, sampleCount), randn(1, sampleCount));
    signal(20000:20020) = signal(20000:20020) * 8;
    interleaved = zeros(1, 2 * sampleCount, 'int16');
    interleaved(1:2:end) = int16(real(signal));
    interleaved(2:2:end) = int16(imag(signal));
    ifPath = fullfile(syntheticDir, 'synthetic_iq_int16.bin');
    fileId = fopen(ifPath, 'wb');
    assert(fileId > 0, 'Could not create synthetic IF file.');
    try
        fwrite(fileId, interleaved, 'int16');
        fclose(fileId);
    catch ME
        fclose(fileId);
        rethrow(ME);
    end

    config = struct();
    config.tag = 'r2026a_compat_probe';
    config.outDir = strrep(probeDir, '\', '/');
    config.filePath = strrep(syntheticDir, '\', '/');
    config.fileName = 'synthetic_iq_int16.bin';
    config.msToProcess = 100;
    config.numberOfChannels = 1;
    config.samplingFreq = fs;
    config.IF = 0;
    config.dataType = 'int16';
    config.fileType = 2;
    config.EnablePB = true;
    config.Th_static_dBm = -30;
    config.probeDurationMs = 100;
    config.skipNumberOfBytes = 0;
    config.usrp = struct('scaleK', -94.72, 'gain', 60);
    config.PB_settings = struct('UseStatic', true, ...
        'falseAlert', 1e-4, 'Th_TTL', 5, 'debugplot', false);
    configPath = fullfile(outputRoot, 'synthetic_probe_config.json');
    localWriteJson(configPath, config);

    probeReport = runProbeIf(configPath, 'outDir', probeDir);
    imageNames = {'probe_spectrum.png', 'probe_time.png', ...
        'probe_hist.png', 'probe_pb_debug.png'};
    imageBytes = zeros(size(imageNames));
    for idx = 1:numel(imageNames)
        info = dir(fullfile(probeDir, 'probe', imageNames{idx}));
        if ~isempty(info), imageBytes(idx) = info.bytes; end
    end

    result = probeReport;
    result.syntheticIf = ifPath;
    result.configPath = configPath;
    result.imageNames = imageNames;
    result.imageBytes = imageBytes;
    result.ok = probeReport.ok && all(imageBytes > 1000);
    if ~result.ok && isempty(result.error)
        result.error = 'One or more probe images were missing or empty.';
    end

    % Confirm every artifact remains inside this run's new output tree.
    canonicalRoot = char(java.io.File(outputRoot).getCanonicalPath());
    canonicalIf = char(java.io.File(ifPath).getCanonicalPath());
    assert(startsWith(lower(canonicalIf), lower(canonicalRoot)), ...
        'Synthetic IF unexpectedly escaped the compatibility output root.');
    assert(startsWith(lower(char(java.io.File(probeDir).getCanonicalPath())), ...
        lower(canonicalRoot)), ...
        'Probe output unexpectedly escaped the compatibility output root.');
    assert(isfolder(rootDir), 'Project root disappeared during probe test.');
end

function tf = localSectionOk(report, name)
    tf = isfield(report, name) && isstruct(report.(name)) && ...
        isfield(report.(name), 'ok') && logical(report.(name).ok);
end

function result = localErrorStruct(errorObject)
    result = struct('ok', false, ...
        'identifier', errorObject.identifier, ...
        'message', errorObject.message, ...
        'report', getReport(errorObject, 'extended', 'hyperlinks', 'off'));
end

function localWriteJson(path, value)
    text = jsonencode(value, 'PrettyPrint', true);
    fileId = fopen(path, 'w', 'n', 'UTF-8');
    assert(fileId > 0, 'Could not write JSON file: %s', path);
    try
        fwrite(fileId, text, 'char');
        fclose(fileId);
    catch ME
        fclose(fileId);
        rethrow(ME);
    end
end

function localCloseGraphics(graphicsObject)
    if ~isempty(graphicsObject) && isgraphics(graphicsObject)
        close(graphicsObject);
    end
end
