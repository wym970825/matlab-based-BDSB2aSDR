function report = exportTrackingFiguresSequential(source, settings, outputDir, varargin)
%EXPORTTRACKINGFIGURESSEQUENTIAL Export one bounded-size figure per channel.
%
% SOURCE is either an in-memory tracking-result array or a directory that
% directly contains Trk_Prn_*_final.mat files. Disk input is deliberately
% loaded one file at a time so long captures do not keep every channel in
% memory while the graphics renderer is active.

    p = inputParser;
    p.FunctionName = 'exportTrackingFiguresSequential';
    addParameter(p, 'ChannelIndices', [], @(x) isnumeric(x) && isvector(x));
    addParameter(p, 'MaxPlotPoints', 20000, ...
        @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 100);
    addParameter(p, 'Resolution', 140, ...
        @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0);
    addParameter(p, 'Visible', false, @localLogicalScalar);
    addParameter(p, 'Overwrite', true, @localLogicalScalar);
    parse(p, varargin{:});
    opt = p.Results;

    outputDir = char(outputDir);
    if ~isfolder(outputDir)
        [ok, message] = mkdir(outputDir);
        if ~ok
            error('exportTrackingFiguresSequential:CreateOutput', ...
                'Cannot create %s: %s', outputDir, message);
        end
    end

    isDiskSource = ischar(source) || (isstring(source) && isscalar(source));
    if isDiskSource
        sourceDir = char(source);
        files = localTrackingFiles(sourceDir);
        nItems = numel(files);
        indices = opt.ChannelIndices;
        if isempty(indices), indices = 1:nItems; end
        indices = indices(indices >= 1 & indices <= nItems);
    else
        nItems = numel(source);
        indices = opt.ChannelIndices;
        if isempty(indices), indices = 1:nItems; end
        indices = indices(indices >= 1 & indices <= nItems);
    end

    report = struct('ok', true, 'outputDir', outputDir, 'prns', [], ...
        'figureFiles', {{}}, 'errors', struct('source', {}, ...
        'identifier', {}, 'message', {}), 'elapsedSeconds', 0);
    started = tic;

    for itemNr = 1:numel(indices)
        idx = indices(itemNr);
        sourceLabel = sprintf('channel %d', idx);
        fig = gobjects(0);
        try
            if isDiskSource
                sourcePath = fullfile(files(idx).folder, files(idx).name);
                sourceLabel = sourcePath;
                loaded = load(sourcePath);
                channel = localFindChannel(loaded, files(idx).prn, sourcePath);
                clear loaded
            else
                channel = source(idx);
            end
            channel = localToStruct(channel);
            prn = localScalar(channel, 'PRN', 0);
            if prn < 1
                continue;
            end
            channel = localTrimChannel(channel);
            outputFile = fullfile(outputDir, ...
                sprintf('PRN_%02d_tracking.png', prn));
            if ~logical(opt.Overwrite) && isfile(outputFile)
                report.prns(end + 1) = prn; %#ok<AGROW>
                report.figureFiles{end + 1} = outputFile; %#ok<AGROW>
                fprintf('  Tracking plot kept for PRN %02d: %s\n', ...
                    prn, outputFile);
                clear channel
                continue;
            end

            fig = localChannelFigure(channel, prn, settings, opt);
            exportgraphics(fig, outputFile, 'Resolution', opt.Resolution);
            close(fig);
            fig = gobjects(0);
            drawnow;
            report.prns(end + 1) = prn; %#ok<AGROW>
            report.figureFiles{end + 1} = outputFile; %#ok<AGROW>
            fprintf('  Tracking plot %d/%d, PRN %02d: %s\n', ...
                itemNr, numel(indices), prn, outputFile);
        catch ME
            if ~isempty(fig) && all(isgraphics(fig)), close(fig); end
            drawnow;
            record = struct('source', sourceLabel, ...
                'identifier', ME.identifier, 'message', ME.message);
            report.errors(end + 1) = record; %#ok<AGROW>
            warning('exportTrackingFiguresSequential:Channel', ...
                'Could not export %s: %s', sourceLabel, ME.message);
        end
        clear channel
    end

    report.elapsedSeconds = toc(started);
    report.ok = isempty(report.errors);
end

function tf = localLogicalScalar(value)
    tf = (islogical(value) || isnumeric(value)) && isscalar(value) ...
        && isfinite(double(value));
end

function files = localTrackingFiles(sourceDir)
    if ~isfolder(sourceDir)
        error('exportTrackingFiguresSequential:MissingSource', ...
            'Tracking directory does not exist: %s', sourceDir);
    end
    files = dir(fullfile(sourceDir, 'Trk_Prn_*_final.mat'));
    files = files(~[files.isdir]);
    prns = nan(1, numel(files));
    for idx = 1:numel(files)
        token = regexp(files(idx).name, ...
            '^Trk_Prn_(\d+)_final\.mat$', 'tokens', 'once');
        if ~isempty(token), prns(idx) = str2double(token{1}); end
    end
    files = files(isfinite(prns));
    prns = prns(isfinite(prns));
    [prns, order] = sort(prns);
    files = files(order);
    for idx = 1:numel(files), files(idx).prn = prns(idx); end
    if isempty(files)
        error('exportTrackingFiguresSequential:NoFiles', ...
            'No final tracking MAT files found in %s.', sourceDir);
    end
end

function channel = localFindChannel(loaded, expectedPrn, sourcePath)
    preferred = {'finalTRes', 'obj', 'trackResults'};
    names = [preferred, setdiff(fieldnames(loaded).', preferred, 'stable')];
    for nameIdx = 1:numel(names)
        value = loaded.(names{nameIdx});
        for valueIdx = 1:numel(value)
            item = value(valueIdx);
            if localHasMember(item, 'PRN')
                prn = localScalar(item, 'PRN', expectedPrn);
                if prn == expectedPrn
                    channel = item;
                    return;
                end
            end
        end
    end
    error('exportTrackingFiguresSequential:BadFile', ...
        'No PRN %d tracking result found in %s.', expectedPrn, sourcePath);
end

function channel = localToStruct(channel)
    if isobject(channel) && ismethod(channel, 'toStruct')
        channel = channel.toStruct();
    end
    if ~isstruct(channel) || ~isscalar(channel)
        error('exportTrackingFiguresSequential:BadChannel', ...
            'Tracking result must be a scalar struct or compatible object.');
    end
end

function channel = localTrimChannel(channel)
    n = localValidLength(channel);
    names = fieldnames(channel);
    cnoInterval = max(1, round(localScalar(channel, 'CNoInterval', 200)));
    cnoNames = {'DataCNo', 'DataPLD', 'PilotCNo', 'PilotPLD', 'B2a_CNo'};
    for idx = 1:numel(names)
        name = names{idx};
        value = channel.(name);
        if ~(isnumeric(value) || islogical(value)) || ~isvector(value) ...
                || isscalar(value)
            continue;
        end
        if ismember(name, cnoNames)
            keep = min(numel(value), max(1, ceil(n / cnoInterval)));
        elseif numel(value) >= n
            keep = n;
        else
            continue;
        end
        channel.(name) = value(1:keep);
    end
    channel.Nsize = n;
end

function n = localValidLength(channel)
    candidates = {'absoluteSample', 'I_P', 'codeFreq', 'remCodePhase'};
    last = [];
    for idx = 1:numel(candidates)
        value = localVector(channel, candidates{idx});
        if isempty(value), continue; end
        finiteLast = find(isfinite(value), 1, 'last');
        if ~isempty(finiteLast), last(end + 1) = finiteLast; end %#ok<AGROW>
    end
    if isempty(last)
        n = max(1, floor(localScalar(channel, 'Nsize', 1)));
    else
        n = min(last);
    end
end

function fig = localChannelFigure(channel, prn, settings, opt)
    fig = figure('Visible', localOnOff(logical(opt.Visible)), 'Color', 'w', ...
        'Position', [60 40 1600 980], 'Name', ...
        sprintf('PRN %02d tracking', prn), 'NumberTitle', 'off');
    layout = tiledlayout(fig, 3, 3, 'TileSpacing', 'compact', ...
        'Padding', 'compact');
    dt = localTimeStep(settings);

    ax = nexttile(layout);
    iPrompt = localVector(channel, 'I_P');
    qPrompt = localVector(channel, 'Q_P');
    nIq = min(numel(iPrompt), numel(qPrompt));
    if nIq > 0
        ii = localIndices(nIq, opt.MaxPlotPoints);
        scatter(ax, double(iPrompt(ii)), double(qPrompt(ii)), 4, ...
            'filled', 'MarkerFaceAlpha', 0.25);
    end
    grid(ax, 'on'); axis(ax, 'equal'); title(ax, 'Prompt IQ');
    xlabel(ax, 'I'); ylabel(ax, 'Q'); localMarkEmpty(ax);

    ax = nexttile(layout);
    localTrace(ax, localPower(channel, 'I_P', 'Q_P'), dt, opt, 'Data');
    localTrace(ax, localPower(channel, 'Pilot_I_P', 'Pilot_Q_P'), ...
        dt, opt, 'Pilot');
    localFinish(ax, 'Prompt power', 'Power', true);

    ax = nexttile(layout);
    cnoStep = dt * max(1, localScalar(channel, 'CNoInterval', ...
        localSetting(settings, 'CNoInterval', 200)));
    localTrace(ax, localVector(channel, 'DataCNo'), cnoStep, opt, 'Data');
    localTrace(ax, localVector(channel, 'PilotCNo'), cnoStep, opt, 'Pilot');
    localTrace(ax, localVector(channel, 'B2a_CNo'), cnoStep, opt, 'B2a');
    localFinish(ax, 'C/N0', 'dB-Hz', true);

    ax = nexttile(layout);
    localTrace(ax, localVector(channel, 'carrFreq'), dt, opt, 'Carrier');
    localFinish(ax, 'Carrier frequency', 'Hz', false);

    ax = nexttile(layout);
    localTrace(ax, localVector(channel, 'codeFreq'), dt, opt, 'Code');
    localFinish(ax, 'Code frequency', 'Hz', false);

    ax = nexttile(layout);
    localTrace(ax, localVector(channel, 'pllDiscr'), dt, opt, 'Raw');
    localTrace(ax, localVector(channel, 'pllDiscrFilt'), dt, opt, 'Filtered');
    localFinish(ax, 'PLL discriminator', 'Error', true);

    ax = nexttile(layout);
    localTrace(ax, localVector(channel, 'dllDiscr'), dt, opt, 'Raw');
    localTrace(ax, localVector(channel, 'dllDiscrFilt'), dt, opt, 'Filtered');
    localFinish(ax, 'DLL discriminator', 'Error', true);

    ax = nexttile(layout);
    localTrace(ax, localVector(channel, 'fllDiscrHz'), dt, opt, 'FLL raw');
    localTrace(ax, localVector(channel, 'fllDiscrFiltHz'), dt, opt, 'FLL filt');
    localTrace(ax, localVector(channel, 'fllCorrHz'), dt, opt, 'FLL corr');
    localTrace(ax, localVector(channel, 'kf_corrHz'), dt, opt, 'KF corr');
    localFinish(ax, 'Frequency corrections', 'Hz', true);

    ax = nexttile(layout);
    state = localVector(channel, 'trk_state');
    if isempty(state), state = localVector(channel, 'cur_state'); end
    localStairs(ax, state, dt, opt, 'State');
    localStairs(ax, localVector(channel, 'fllAided'), dt, opt, 'FLL aided');
    localFinish(ax, 'Tracking state', 'State / flag', true);

    sgtitle(layout, sprintf('PRN %02d | status %s | valid N=%d', ...
        prn, localText(channel, 'status', '?'), channel.Nsize), ...
        'Interpreter', 'none');
end

function localTrace(ax, value, step, opt, label)
    if isempty(value), return; end
    value = double(value(:).');
    ii = localIndices(numel(value), opt.MaxPlotPoints);
    hold(ax, 'on');
    plot(ax, (ii - 1) * step, value(ii), 'LineWidth', 0.8, ...
        'DisplayName', label);
end

function localStairs(ax, value, step, opt, label)
    if isempty(value), return; end
    value = double(value(:).');
    ii = localIndices(numel(value), opt.MaxPlotPoints);
    hold(ax, 'on');
    stairs(ax, (ii - 1) * step, value(ii), 'LineWidth', 0.8, ...
        'DisplayName', label);
end

function ii = localIndices(n, maxPoints)
    if n <= maxPoints
        ii = 1:n;
    else
        ii = unique(round(linspace(1, n, floor(maxPoints))));
    end
end

function localFinish(ax, plotTitle, yText, showLegend)
    grid(ax, 'on'); xlabel(ax, 'Time (s)'); ylabel(ax, yText);
    title(ax, plotTitle); localMarkEmpty(ax);
    if showLegend && ~isempty(findobj(ax, '-property', 'DisplayName'))
        legend(ax, 'show', 'Location', 'best');
    end
end

function localMarkEmpty(ax)
    % Stair charts are not Type='line'. Check the shared data property so
    % actual state traces never receive the empty-panel annotation.
    if isempty(findobj(ax, '-property', 'YData'))
        text(ax, 0.5, 0.5, 'No saved data', 'Units', 'normalized', ...
            'HorizontalAlignment', 'center', 'Color', [0.4 0.4 0.4]);
    end
end

function value = localPower(channel, iName, qName)
    iValue = localVector(channel, iName);
    qValue = localVector(channel, qName);
    n = min(numel(iValue), numel(qValue));
    if n < 1
        value = [];
    else
        value = double(iValue(1:n)).^2 + double(qValue(1:n)).^2;
    end
end

function value = localVector(container, name)
    value = [];
    if localHasMember(container, name), value = container.(name); end
    if ~(isnumeric(value) || islogical(value)) || ~isvector(value)
        value = [];
    end
end

function tf = localHasMember(container, name)
    tf = (isstruct(container) && isfield(container, name)) ...
        || (isobject(container) && isprop(container, name));
end

function value = localScalar(container, name, fallback)
    value = fallback;
    if localHasMember(container, name)
        candidate = container.(name);
        if isnumeric(candidate) && isscalar(candidate) && isfinite(candidate)
            value = double(candidate);
        end
    end
end

function value = localText(container, name, fallback)
    value = fallback;
    if localHasMember(container, name)
        candidate = container.(name);
        if ischar(candidate) || (isstring(candidate) && isscalar(candidate))
            value = char(candidate);
        end
    end
end

function value = localSetting(settings, name, fallback)
    value = fallback;
    if isstruct(settings) && isfield(settings, name) ...
            && isnumeric(settings.(name)) && isscalar(settings.(name)) ...
            && isfinite(settings.(name))
        value = double(settings.(name));
    end
end

function step = localTimeStep(settings)
    step = localSetting(settings, 'intTime', 1e-3);
    if step <= 0, step = 1e-3; end
end

function value = localOnOff(tf)
    if tf, value = 'on'; else, value = 'off'; end
end
