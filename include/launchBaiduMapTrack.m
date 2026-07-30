function outDir = launchBaiduMapTrack(navSolutions, settings, varargin)
%LAUNCHBAIDUMAPTRACK Export WGS84 track and open Baidu Map JSAPI 4.0 web UI.
%
%   outDir = launchBaiduMapTrack(navSolutions, settings)
%   outDir = launchBaiduMapTrack(..., 'outDir', dir, 'openBrowser', true)
%
% GNSS solutions are WGS84. Baidu Maps uses BD-09. The web page converts
% WGS84 -> BD-09 via BMap.Convertor.translate (from=1, to=5) per official
% JSAPI 4.0 docs before drawing Polyline / Markers.
%
% AK is read from config/BaidumapKey.txt (gitignored).

    p = inputParser;
    addParameter(p, 'outDir', '', @(x) ischar(x) || isstring(x));
    addParameter(p, 'openBrowser', true, @islogical);
    addParameter(p, 'keyFile', '', @(x) ischar(x) || isstring(x));
    parse(p, varargin{:});
    opt = p.Results;

    rootDir = fileparts(fileparts(mfilename('fullpath')));
    webTplDir = fullfile(rootDir, 'web', 'baidumap');

    if isempty(opt.outDir)
        stamp = string(datetime('now'), 'yyMMdd_HHmmss');
        outDir = fullfile(settings.resultRoot, sprintf('baidumap_%s', stamp));
    else
        outDir = char(opt.outDir);
        if isempty(outDir)
            stamp = string(datetime('now'), 'yyMMdd_HHmmss');
            outDir = fullfile(settings.resultRoot, sprintf('baidumap_%s', stamp));
        end
    end
    if ~exist(outDir, 'dir')
        mkdir(outDir);
    end

    % Key
    if ~isempty(opt.keyFile)
        ak = loadBaiduMapKey(opt.keyFile);
    elseif isfield(settings, 'baiduMapKeyFile') && ~isempty(settings.baiduMapKeyFile)
        ak = loadBaiduMapKey(settings.baiduMapKeyFile);
    else
        ak = loadBaiduMapKey();
    end

    % Track points (WGS84 degrees)
    if ~isfield(navSolutions, 'latitude') || ~isfield(navSolutions, 'longitude')
        error('launchBaiduMapTrack:NoLLA', 'navSolutions missing latitude/longitude');
    end
    lat = navSolutions.latitude(:);
    lon = navSolutions.longitude(:);
    h = [];
    if isfield(navSolutions, 'height')
        h = navSolutions.height(:);
    end
    ok = isfinite(lat) & isfinite(lon);
    if ~any(ok)
        warning('launchBaiduMapTrack:NoFixes', 'No valid lat/lon — skip Baidu Map UI.');
        outDir = '';
        return;
    end
    lat = lat(ok);
    lon = lon(ok);
    if isempty(h)
        h = nan(size(lat));
    else
        h = h(ok);
    end
    tMs = (0:numel(lat)-1)' * settings.navSolPeriod;

    track = struct();
    track.coord = 'WGS84';
    track.note = 'Convert WGS84->BD-09 with BMap.Convertor before display';
    track.navSolPeriodMs = settings.navSolPeriod;
    track.nPoints = numel(lat);
    track.meanLat = mean(lat);
    track.meanLon = mean(lon);
    track.points = arrayfun(@(i) struct( ...
        'lng', lon(i), 'lat', lat(i), 'h', h(i), 'tMs', tMs(i)), ...
        (1:numel(lat))');

    jsonPath = fullfile(outDir, 'track.json');
    writeTrackJson(jsonPath, track);

    % Build index.html from template
    tplHtml = fullfile(webTplDir, 'index.template.html');
    tplJs   = fullfile(webTplDir, 'track.template.js');
    if ~isfile(tplHtml) || ~isfile(tplJs)
        error('launchBaiduMapTrack:Template', ...
            'Missing web templates under %s', webTplDir);
    end

    try
        trackJsonEmbed = jsonencode(track);
    catch
        trackJsonEmbed = fileread(jsonPath);
    end

    html = fileread(tplHtml);
    html = strrep(html, '{{BAIDU_AK}}', ak);
    html = strrep(html, '{{TRACK_JSON_EMBED}}', trackJsonEmbed);
    html = strrep(html, '{{TITLE}}', sprintf('B2a PVT track (N=%d)', numel(lat)));

    js = fileread(tplJs);

    htmlOut = fullfile(outDir, 'index.html');
    jsOut   = fullfile(outDir, 'track.js');
    writeTextFile(htmlOut, html);
    writeTextFile(jsOut, js);
    % copy README snippet if present
    readmeSrc = fullfile(webTplDir, 'README.md');
    if isfile(readmeSrc)
        copyfile(readmeSrc, fullfile(outDir, 'README.md'));
    end

    fprintf('Baidu Map UI written: %s\n', htmlOut);
    fprintf('  points: %d  mean WGS84 (%.6f, %.6f)\n', numel(lat), mean(lat), mean(lon));

    if opt.openBrowser
        openInBrowser(htmlOut);
    end
end

function writeTrackJson(path, track)
    % Prefer jsonencode (R2016b+)
    try
        txt = jsonencode(track);
    catch
        % Minimal fallback
        n = track.nPoints;
        pts = cell(n, 1);
        for i = 1:n
            p = track.points(i);
            pts{i} = sprintf('{"lng":%.8f,"lat":%.8f,"h":%.3f,"tMs":%g}', ...
                p.lng, p.lat, p.h, p.tMs);
        end
        txt = sprintf(['{"coord":"WGS84","nPoints":%d,"meanLat":%.8f,' ...
            '"meanLon":%.8f,"navSolPeriodMs":%g,"points":[%s]}'], ...
            n, track.meanLat, track.meanLon, track.navSolPeriodMs, strjoin(pts, ','));
    end
    writeTextFile(path, txt);
end

function writeTextFile(path, txt)
    fid = fopen(path, 'w', 'n', 'UTF-8');
    if fid < 0
        error('launchBaiduMapTrack:Write', 'Cannot write %s', path);
    end
    cleaner = onCleanup(@() fclose(fid));
    fwrite(fid, txt, 'char');
end

function openInBrowser(htmlPath)
    htmlPath = char(htmlPath);
    % Prefer MATLAB web; fall back to OS default browser
    try
        web(htmlPath, '-browser');
        return;
    catch
    end
    if ispc
        system(sprintf('start "" "%s"', htmlPath));
    elseif ismac
        system(sprintf('open "%s"', htmlPath));
    else
        system(sprintf('xdg-open "%s"', htmlPath));
    end
end
