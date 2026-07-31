function outDir = smoke_nav_plot_baidu(varargin)
%SMOKE_NAV_PLOT_BAIDU Replay post-PVT plots + Baidu Map UI from a saved nav mat.
%
%   outDir = smoke_nav_plot_baidu()
%   outDir = smoke_nav_plot_baidu('matPath', '.../results_renav_satpos1fix.mat')
%
% Looks for navSolutions / nav2 / report.navSolutions in the mat file.

    setupPaths();
    p = inputParser;
    addParameter(p, 'matPath', ...
        fullfile('results', 'smoke', 'fullsky_pvt60_260731_063450', 'results.mat'), ...
        @(x) ischar(x) || isstring(x));
    addParameter(p, 'outDir', fullfile('results', 'smoke', 'navplot_display_smoke'), ...
        @(x) ischar(x) || isstring(x));
    addParameter(p, 'openBaiduMap', true, @islogical);
    addParameter(p, 'reNav', false, @islogical);
    parse(p, varargin{:});

    matPath = char(p.Results.matPath);
    outDir  = char(p.Results.outDir);
    if ~isfile(matPath)
        error('smoke_nav_plot_baidu:Missing', 'Mat not found: %s', matPath);
    end
    if ~exist(outDir, 'dir'), mkdir(outDir); end

    S = load(matPath);
    ns = [];
    if isfield(S, 'navSolutions'), ns = S.navSolutions;
    elseif isfield(S, 'nav2'), ns = S.nav2;
    elseif isfield(S, 'report') && isfield(S.report, 'navSolutions')
        ns = S.report.navSolutions;
    elseif isfield(S, 'results') && isfield(S.results, 'navSolutions')
        ns = S.results.navSolutions;
    end
    settings = initSettings();
    settings.plotNavPost = true;
    settings.plotBaiduMap = p.Results.openBaiduMap;
    settings.plotNavLegacy = false;

    if isempty(ns) || p.Results.reNav
        tr = [];
        if isfield(S, 'trackResults'), tr = S.trackResults;
        elseif isfield(S, 'report') && isfield(S.report, 'trackResults')
            tr = S.report.trackResults;
        end
        if isempty(tr)
            error('smoke_nav_plot_baidu:NoNav', 'No navSolutions/trackResults in %s', matPath);
        end
        if ~isstruct(tr), tr = trackResultsToStruct(tr); end
        settings.msToProcess = max(settings.msToProcess, 280000);
        [ns, ~] = postNavigation(tr, settings);
    end
    if isempty(ns)
        error('smoke_nav_plot_baidu:NoNav', 'Empty navSolutions after load/reNav');
    end

    set(0, 'DefaultFigureVisible', 'on');
    plotNavPost(ns, settings, 'saveDir', outDir, 'doLegacy', false, ...
        'openBaiduMap', p.Results.openBaiduMap);
    fprintf('smoke_nav_plot_baidu: outDir=%s  nFixes~%d\n', outDir, ...
        nnz(isfinite(ns.latitude)));
end
