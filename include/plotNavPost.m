function figs = plotNavPost(navSolutions, settings, varargin)
%PLOTNAVPOST Post-PVT figures: ENU time series, sky plot, LLA geoshow scatter.
%
%   figs = plotNavPost(navSolutions, settings)
%   figs = plotNavPost(navSolutions, settings, 'saveDir', outDir, 'doLegacy', true)
%
% Figures (when data available):
%   1) ENU variations vs measurement epoch (relative to mean or truePosition)
%   2) Satellite sky / zenith plot (az/el)
%   3) Latitude–longitude 2D scatter via geoshow (Mapping Toolbox) with
%      plain plot fallback
%
% Also calls legacy plotNavigation when 'doLegacy' is true (default).

    p = inputParser;
    addParameter(p, 'saveDir', '', @(x) ischar(x) || isstring(x));
    addParameter(p, 'doLegacy', true, @islogical);
    addParameter(p, 'openBaiduMap', [], @(x) isempty(x) || islogical(x));
    parse(p, varargin{:});
    opt = p.Results;
    figs = struct('enu', [], 'sky', [], 'lla', [], 'legacy', []);

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

    %% Reference ENU -------------------------------------------------------
    [refE, refN, refU, refLabel] = localEnuReference(navSolutions, settings);
    tEpoch = (0:numel(navSolutions.E)-1) * settings.navSolPeriod / 1000; % s

    dE = navSolutions.E - refE;
    dN = navSolutions.N - refN;
    dU = navSolutions.U - refU;

    %% 1) ENU variations ---------------------------------------------------
    figs.enu = figure('Name', 'PVT ENU variations', 'NumberTitle', 'off', 'Color', 'w');
    tl = tiledlayout(figs.enu, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    nexttile; plot(tEpoch, dE, 'b.-'); grid on; ylabel('\Delta E (m)');
    title(sprintf('ENU vs time  (ref: %s)', refLabel));
    nexttile; plot(tEpoch, dN, 'g.-'); grid on; ylabel('\Delta N (m)');
    nexttile; plot(tEpoch, dU, 'r.-'); grid on; ylabel('\Delta U (m)');
    xlabel(tl, sprintf('Time (s), navSolPeriod = %g ms', settings.navSolPeriod));
    if ~isempty(saveDir)
        saveas(figs.enu, fullfile(saveDir, 'enu_variations.png'));
    end

    %% 2) Sky / zenith plot ------------------------------------------------
    figs.sky = figure('Name', 'PVT sky plot', 'NumberTitle', 'off', 'Color', 'w');
    axSky = axes(figs.sky);
    try
        if isfield(navSolutions, 'az') && isfield(navSolutions, 'el') ...
                && isfield(navSolutions, 'PRN')
            prnCol = navSolutions.PRN(:, 1);
            skyPlot(axSky, navSolutions.az, navSolutions.el, prnCol);
            pdop = NaN;
            if isfield(navSolutions, 'DOP') && ~isempty(navSolutions.DOP)
                pdop = mean(navSolutions.DOP(2, isfinite(navSolutions.DOP(2, :))));
            end
            title(axSky, sprintf('Sky plot (mean PDOP: %.2f)', pdop));
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

    %% 3) LLA scatter (geoshow preferred) ----------------------------------
    lat = navSolutions.latitude(:);
    lon = navSolutions.longitude(:);
    ok = isfinite(lat) & isfinite(lon);
    figs.lla = figure('Name', 'PVT LLA scatter (geoshow)', 'NumberTitle', 'off', 'Color', 'w');
    axLla = axes(figs.lla);
    if ~any(ok)
        text(axLla, 0.5, 0.5, 'No valid lat/lon fixes', ...
            'HorizontalAlignment', 'center');
        axis(axLla, 'off');
    else
        latOk = lat(ok);
        lonOk = lon(ok);
        usedGeoshow = false;
        try
            if license('test', 'map_toolbox') && exist('geoshow', 'file') == 2
                figure(figs.lla); clf(figs.lla);
                dLat = max(0.02, 0.5 * (max(latOk) - min(latOk)) + 0.005);
                dLon = max(0.02, 0.5 * (max(lonOk) - min(lonOk)) + 0.005);
                latlim = [min(latOk)-dLat, max(latOk)+dLat];
                lonlim = [min(lonOk)-dLon, max(lonOk)+dLon];
                axesm('MapProjection', 'mercator', ...
                    'MapLatLimit', latlim, 'MapLonLimit', lonlim, ...
                    'Frame', 'on', 'Grid', 'on', 'MeridianLabel', 'on', ...
                    'ParallelLabel', 'on');
                geoshow(latOk, lonOk, 'DisplayType', 'point', ...
                    'Marker', '.', 'MarkerSize', 12, 'Color', [0.1 0.35 0.75]);
                geoshow(latOk, lonOk, 'DisplayType', 'line', ...
                    'Color', [0.85 0.25 0.15], 'LineWidth', 1.2);
                geoshow(latOk(1), lonOk(1), 'DisplayType', 'point', ...
                    'Marker', 'o', 'MarkerSize', 8, 'MarkerEdgeColor', 'k', ...
                    'MarkerFaceColor', [0.2 0.8 0.3]);
                geoshow(latOk(end), lonOk(end), 'DisplayType', 'point', ...
                    'Marker', 's', 'MarkerSize', 8, 'MarkerEdgeColor', 'k', ...
                    'MarkerFaceColor', [0.9 0.2 0.2]);
                title(sprintf('LLA scatter (geoshow)  N=%d  mean (%.5f, %.5f)', ...
                    nnz(ok), mean(latOk), mean(lonOk)));
                usedGeoshow = true;
            end
        catch ME
            warning('plotNavPost:Geoshow', 'geoshow path failed: %s', ME.message);
            usedGeoshow = false;
            figure(figs.lla); clf(figs.lla);
            axLla = axes(figs.lla);
        end
        if ~usedGeoshow
            if ~ishandle(axLla) || ~strcmp(get(axLla, 'Type'), 'axes')
                axLla = axes(figs.lla);
            end
            plot(axLla, lonOk, latOk, 'b.-', 'MarkerSize', 10);
            hold(axLla, 'on');
            plot(axLla, lonOk(1), latOk(1), 'go', 'MarkerFaceColor', 'g', 'MarkerSize', 8);
            plot(axLla, lonOk(end), latOk(end), 'rs', 'MarkerFaceColor', 'r', 'MarkerSize', 8);
            hold(axLla, 'off');
            grid(axLla, 'on');
            axis(axLla, 'equal');
            xlabel(axLla, 'Longitude (deg, WGS84)');
            ylabel(axLla, 'Latitude (deg, WGS84)');
            title(axLla, sprintf('LLA scatter (plot fallback)  N=%d  mean (%.5f, %.5f)', ...
                nnz(ok), mean(latOk), mean(lonOk)));
            legend(axLla, {'track', 'start', 'end'}, 'Location', 'best');
        end
    end
    if ~isempty(saveDir)
        saveas(figs.lla, fullfile(saveDir, 'lla_geoshow.png'));
    end

    %% Legacy SoftGNSS combined figure ------------------------------------
    if opt.doLegacy
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

function [refE, refN, refU, label] = localEnuReference(navSolutions, settings)
    if isfield(settings, 'truePosition') ...
            && isfinite(settings.truePosition.E) && isfinite(settings.truePosition.N) ...
            && isfinite(settings.truePosition.U)
        refE = settings.truePosition.E;
        refN = settings.truePosition.N;
        refU = settings.truePosition.U;
        label = 'truePosition';
    else
        refE = mean(navSolutions.E(isfinite(navSolutions.E)));
        refN = mean(navSolutions.N(isfinite(navSolutions.N)));
        refU = mean(navSolutions.U(isfinite(navSolutions.U)));
        if ~isfinite(refE), refE = 0; end
        if ~isfinite(refN), refN = 0; end
        if ~isfinite(refU), refU = 0; end
        label = 'mean ENU';
    end
end
