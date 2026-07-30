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
        fullfile('results', 'smoke', 'fullsky_pvt60_260730_173603', 'results_renav_satpos1fix.mat'), ...
        @(x) ischar(x) || isstring(x));
    addParameter(p, 'outDir', fullfile('results', 'smoke', 'navplot_v013_smoke'), ...
        @(x) ischar(x) || isstring(x));
    addParameter(p, 'openBaiduMap', true, @islogical);
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
    if isempty(ns)
        error('smoke_nav_plot_baidu:NoNav', 'No navSolutions/nav2 in %s', matPath);
    end

    settings = initSettings('plotBaiduMap', p.Results.openBaiduMap);
    set(0, 'DefaultFigureVisible', 'on');
    plotNavPost(ns, settings, 'saveDir', outDir, 'doLegacy', true, ...
        'openBaiduMap', p.Results.openBaiduMap);
    fprintf('smoke_nav_plot_baidu: outDir=%s\n', outDir);
end
