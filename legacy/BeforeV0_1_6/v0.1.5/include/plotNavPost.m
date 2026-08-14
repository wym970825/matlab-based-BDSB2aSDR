function figs = plotNavPost(navSolutions, settings, varargin)
%PLOTNAVPOST Post-PVT figures: ENU, velocity, DOP, geo basemap, Baidu UI.
%
%   figs = plotNavPost(navSolutions, settings)
%   figs = plotNavPost(..., 'saveDir', outDir, 'silent', false)
%
% Track is aggregated in time order via navTrackTimeOrder before any plot.
%
% Figures (when settings.plotNavPost is true, default):
%   1) ENU displacement vs time
%   2) ENU velocity vs time
%   3) GDOP / HDOP / VDOP vs time
%   4) Sky plot
%   5) LLA map: geobasemap('streets-light') + time-coloured points,
%      trajectory, start/end markers
%
% Baidu web UI when settings.plotBaiduMap (default true).
% Silent: settings.plotNavPost=false or 'silent',true skips all figures.

    p = inputParser;
    addParameter(p, 'saveDir', '', @(x) ischar(x) || isstring(x));
    addParameter(p, 'doLegacy', [], @(x) isempty(x) || islogical(x));
    addParameter(p, 'openBaiduMap', [], @(x) isempty(x) || islogical(x));
    addParameter(p, 'silent', [], @(x) isempty(x) || islogical(x));
    parse(p, varargin{:});
    opt = p.Results;
    figs = struct('enu', [], 'vel', [], 'dop', [], 'sky', [], 'lla', [], 'legacy', []);

    % Master silent switch (default ON = plot)
    silent = false;
    if ~isempty(opt.silent)
        silent = logical(opt.silent);
    elseif isfield(settings, 'plotNavPost') && ~isempty(settings.plotNavPost)
        silent = ~logical(settings.plotNavPost);
    end
    if silent
        return;
    end

    if isempty(navSolutions)
        disp('plotNavPost: No navigation data to plot.');
        return;
    end
    if ~isfield(navSolutions, 'latitude') || isempty(navSolutions.latitude)
        disp('plotNavPost: navSolutions has no latitude field.');
        return;
    end

    saveDir = char(opt.saveDir);
    if ~isempty(saveDir) && ~exist(saveDir, 'dir')
        mkdir(saveDir);
    end

    %% Time-ordered track (+ ENU jump filter) ------------------------------
    trk = navTrackTimeOrder(navSolutions, settings);
    if trk.n < 1
        disp('plotNavPost: No valid lat/lon fixes after time-order / jump filter.');
        return;
    end
    if isfield(trk, 'nRemovedJump') && trk.nRemovedJump > 0
        fprintf('plotNavPost: track N=%d after removing %d ENU jump point(s) (v>%g m/s)\n', ...
            trk.n, trk.nRemovedJump, trk.maxSpeedMps);
    end

    [refE, refN, refU, refLabel] = localEnuReference(trk, settings);
    dE = trk.E - refE;
    dN = trk.N - refN;
    dU = trk.U - refU;
    t = trk.t(:);

    %% 1) ENU displacement -------------------------------------------------
    figs.enu = figure('Name', 'PVT ENU displacement', 'NumberTitle', 'off', 'Color', 'w');
    tl = tiledlayout(figs.enu, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    nexttile; plot(t, dE, 'b.-', 'MarkerSize', 8); grid on; ylabel('\Delta E (m)');
    title(sprintf('ENU displacement  (ref: %s)  N=%d', refLabel, trk.n));
    nexttile; plot(t, dN, 'g.-', 'MarkerSize', 8); grid on; ylabel('\Delta N (m)');
    nexttile; plot(t, dU, 'r.-', 'MarkerSize', 8); grid on; ylabel('\Delta U (m)');
    xlabel(tl, sprintf('Time (s), navSolPeriod = %g ms', trk.navSolPeriodMs));
    if ~isempty(saveDir)
        saveas(figs.enu, fullfile(saveDir, 'enu_displacement.png'));
    end

    %% 2) ENU velocity -----------------------------------------------------
    figs.vel = figure('Name', 'PVT ENU velocity', 'NumberTitle', 'off', 'Color', 'w');
    tlV = tiledlayout(figs.vel, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    [vE, vN, vU, tMid] = localEnuVelocity(t, dE, dN, dU);
    nexttile; plot(tMid, vE, 'b.-', 'MarkerSize', 8); grid on; ylabel('v_E (m/s)');
    title(sprintf('ENU velocity  N=%d intervals', numel(tMid)));
    nexttile; plot(tMid, vN, 'g.-', 'MarkerSize', 8); grid on; ylabel('v_N (m/s)');
    nexttile; plot(tMid, vU, 'r.-', 'MarkerSize', 8); grid on; ylabel('v_U (m/s)');
    xlabel(tlV, 'Time (s)');
    if ~isempty(saveDir)
        saveas(figs.vel, fullfile(saveDir, 'enu_velocity.png'));
    end

    %% 3) GDOP / HDOP / VDOP -----------------------------------------------
    figs.dop = figure('Name', 'PVT DOP', 'NumberTitle', 'off', 'Color', 'w');
    hold on; grid on;
    hasDop = false;
    if any(isfinite(trk.GDOP))
        plot(t, trk.GDOP, 'k.-', 'DisplayName', 'GDOP'); hasDop = true;
    end
    if any(isfinite(trk.HDOP))
        plot(t, trk.HDOP, 'b.-', 'DisplayName', 'HDOP'); hasDop = true;
    end
    if any(isfinite(trk.VDOP))
        plot(t, trk.VDOP, 'r.-', 'DisplayName', 'VDOP'); hasDop = true;
    end
    if any(isfinite(trk.PDOP))
        plot(t, trk.PDOP, 'Color', [0.5 0.5 0.5], 'LineStyle', '--', ...
            'DisplayName', 'PDOP'); hasDop = true;
    end
    if hasDop
        legend('Location', 'best');
        ylabel('DOP');
        title(sprintf('GDOP / HDOP / VDOP  (median GDOP=%.2f HDOP=%.2f VDOP=%.2f)', ...
            localMed(trk.GDOP), localMed(trk.HDOP), localMed(trk.VDOP)));
    else
        text(0.5, 0.5, 'No DOP data', 'Units', 'normalized', ...
            'HorizontalAlignment', 'center');
        axis off;
    end
    xlabel('Time (s)');
    if ~isempty(saveDir)
        saveas(figs.dop, fullfile(saveDir, 'dop.png'));
    end

    %% 4) Sky / zenith plot ------------------------------------------------
    figs.sky = figure('Name', 'PVT sky plot', 'NumberTitle', 'off', 'Color', 'w');
    axSky = axes(figs.sky);
    try
        if isfield(navSolutions, 'az') && isfield(navSolutions, 'el') ...
                && isfield(navSolutions, 'PRN')
            prnCol = navSolutions.PRN(:, min(1, size(navSolutions.PRN, 2)));
            if size(navSolutions.PRN, 2) >= 1
                prnCol = navSolutions.PRN(:, 1);
            end
            skyPlot(axSky, navSolutions.az, navSolutions.el, prnCol);
            title(axSky, sprintf('Sky plot (median PDOP: %.2f)', localMed(trk.PDOP)));
        else
            text(0.5, 0.5, 'No az/el/PRN for sky plot', 'HorizontalAlignment', 'center');
            axis(axSky, 'off');
        end
    catch ME
        cla(axSky);
        text(0.5, 0.5, ['skyPlot failed: ' ME.message], ...
            'HorizontalAlignment', 'center', 'Interpreter', 'none');
        axis(axSky, 'off');
        warning('plotNavPost:Sky', '%s', ME.message);
    end
    if ~isempty(saveDir)
        saveas(figs.sky, fullfile(saveDir, 'sky_plot.png'));
    end

    %% 5) LLA map — geobasemap streets-light + time heat -------------------
    figs.lla = figure('Name', 'PVT track (geobasemap)', 'NumberTitle', 'off', 'Color', 'w');
    usedGeo = false;
    try
        if exist('geoaxes', 'file') == 2 && exist('geobasemap', 'file') == 2
            gx = geoaxes(figs.lla);
            try
                geobasemap(gx, 'streets-light');
            catch
                try
                    geobasemap(gx, 'streets');
                catch
                    geobasemap(gx, 'grayland');
                end
            end
            hold(gx, 'on');
            % Time colour: normalised elapsed time [0,1]
            tCol = (t - t(1));
            if t(end) > t(1)
                tCol = tCol / (t(end) - t(1));
            else
                tCol = zeros(size(t));
            end
            % Trajectory line (neutral) then heat scatter
            if trk.n >= 2
                geoplot(gx, trk.lat, trk.lon, '-', 'Color', [0.4 0.4 0.45], ...
                    'LineWidth', 1.4, 'DisplayName', 'track');
            end
            if exist('geoscatter', 'file') == 2
                geoscatter(gx, trk.lat, trk.lon, 28, tCol, 'filled', ...
                    'MarkerFaceAlpha', 0.85, 'DisplayName', 'time');
                % Start / end (circle / square)
                geoscatter(gx, trk.lat(1), trk.lon(1), 120, ...
                    'filled', 'Marker', 'o', ...
                    'MarkerFaceColor', [0.15 0.75 0.25], ...
                    'MarkerEdgeColor', 'k', 'LineWidth', 1.2, ...
                    'DisplayName', 'start');
                geoscatter(gx, trk.lat(end), trk.lon(end), 120, ...
                    'filled', 'Marker', 'square', ...
                    'MarkerFaceColor', [0.9 0.2 0.15], ...
                    'MarkerEdgeColor', 'k', 'LineWidth', 1.2, ...
                    'DisplayName', 'end');
            else
                geoplot(gx, trk.lat, trk.lon, '.', 'Color', [0.15 0.45 0.85], ...
                    'MarkerSize', 12, 'DisplayName', 'points');
                geoplot(gx, trk.lat(1), trk.lon(1), 'go', 'MarkerFaceColor', 'g', ...
                    'MarkerSize', 10, 'DisplayName', 'start');
                geoplot(gx, trk.lat(end), trk.lon(end), 'rs', 'MarkerFaceColor', 'r', ...
                    'MarkerSize', 10, 'DisplayName', 'end');
            end
            try
                colormap(gx, turbo(256));
            catch
                colormap(gx, parula(256));
            end
            try
                cb = colorbar(gx);
                cb.Label.String = 'Normalised time (start \rightarrow end)';
            catch
            end
            title(gx, sprintf(['PVT track  N=%d  start(%.5f,%.5f) \\rightarrow ' ...
                'end(%.5f,%.5f)  mean h=%.1f m'], ...
                trk.n, trk.lat(1), trk.lon(1), trk.lat(end), trk.lon(end), trk.meanH));
            try
                legend(gx, 'Location', 'best');
            catch
            end
            usedGeo = true;
        end
    catch ME
        warning('plotNavPost:Geo', 'geobasemap path failed: %s', ME.message);
        usedGeo = false;
        figure(figs.lla); clf(figs.lla);
    end

    if ~usedGeo
        ax = axes(figs.lla);
        tCol = (t - t(1));
        if t(end) > t(1), tCol = tCol / (t(end) - t(1)); else, tCol = zeros(size(t)); end
        hold(ax, 'on');
        if trk.n >= 2
            plot(ax, trk.lon, trk.lat, '-', 'Color', [0.4 0.4 0.45], 'LineWidth', 1.2);
        end
        scatter(ax, trk.lon, trk.lat, 28, tCol, 'filled', 'MarkerFaceAlpha', 0.85);
        plot(ax, trk.lon(1), trk.lat(1), 'o', 'MarkerSize', 10, ...
            'MarkerFaceColor', [0.15 0.75 0.25], 'MarkerEdgeColor', 'k');
        plot(ax, trk.lon(end), trk.lat(end), 's', 'MarkerSize', 10, ...
            'MarkerFaceColor', [0.9 0.2 0.15], 'MarkerEdgeColor', 'k');
        try, colormap(ax, turbo(256)); catch, colormap(ax, parula(256)); end
        cb = colorbar(ax); cb.Label.String = 'Normalised time';
        grid(ax, 'on'); axis(ax, 'equal');
        xlabel(ax, 'Longitude (deg, WGS84)');
        ylabel(ax, 'Latitude (deg, WGS84)');
        title(ax, sprintf('PVT track (fallback)  N=%d  mean (%.5f, %.5f)', ...
            trk.n, trk.meanLat, trk.meanLon));
        legend(ax, {'track', 'time', 'start', 'end'}, 'Location', 'best');
    end
    if ~isempty(saveDir)
        saveas(figs.lla, fullfile(saveDir, 'lla_geobasemap.png'));
    end

    %% Legacy SoftGNSS combined figure ------------------------------------
    doLegacy = opt.doLegacy;
    if isempty(doLegacy)
        if isfield(settings, 'plotNavLegacy')
            doLegacy = logical(settings.plotNavLegacy);
        else
            doLegacy = false;
        end
    end
    if doLegacy
        try
            plotNavigation(navSolutions, settings);
            figs.legacy = gcf;
        catch ME
            warning('plotNavPost:Legacy', 'plotNavigation failed: %s', ME.message);
        end
    end

    %% Optional Baidu Map web UI ------------------------------------------
    doBaidu = opt.openBaiduMap;
    if isempty(doBaidu)
        doBaidu = ~isfield(settings, 'plotBaiduMap') || logical(settings.plotBaiduMap);
    end
    if doBaidu
        try
            launchBaiduMapTrack(navSolutions, settings, 'outDir', saveDir);
        catch ME
            warning('plotNavPost:Baidu', 'Baidu Map UI failed: %s', ME.message);
        end
    end
end

function [refE, refN, refU, label] = localEnuReference(trk, settings)
    if isfield(settings, 'truePosition') ...
            && isfinite(settings.truePosition.E) && isfinite(settings.truePosition.N) ...
            && isfinite(settings.truePosition.U)
        refE = settings.truePosition.E;
        refN = settings.truePosition.N;
        refU = settings.truePosition.U;
        label = 'truePosition';
    else
        refE = mean(trk.E(isfinite(trk.E)));
        refN = mean(trk.N(isfinite(trk.N)));
        refU = mean(trk.U(isfinite(trk.U)));
        if ~isfinite(refE), refE = 0; end
        if ~isfinite(refN), refN = 0; end
        if ~isfinite(refU), refU = 0; end
        label = 'mean ENU';
    end
end

function [vE, vN, vU, tMid] = localEnuVelocity(t, dE, dN, dU)
    t = t(:); dE = dE(:); dN = dN(:); dU = dU(:);
    if numel(t) < 2
        vE = []; vN = []; vU = []; tMid = [];
        return;
    end
    dt = diff(t);
    dt(dt <= 0) = NaN;
    vE = diff(dE) ./ dt;
    vN = diff(dN) ./ dt;
    vU = diff(dU) ./ dt;
    tMid = t(1:end-1) + dt / 2;
    % Drop non-finite velocity samples
    ok = isfinite(vE) & isfinite(vN) & isfinite(tMid);
    vE = vE(ok); vN = vN(ok); vU = vU(ok); tMid = tMid(ok);
end

function m = localMed(x)
    x = x(isfinite(x));
    if isempty(x), m = NaN; else, m = median(x); end
end
