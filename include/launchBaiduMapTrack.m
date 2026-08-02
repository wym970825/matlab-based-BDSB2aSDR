function outDir = launchBaiduMapTrack(navSolutions, settings, varargin)
%LAUNCHBAIDUMAPTRACK Export WGS84 track and open Baidu Map JSAPI 4.0 web UI.
%
%   outDir = launchBaiduMapTrack(navSolutions, settings)
%   outDir = launchBaiduMapTrack(..., 'outDir', dir, 'openBrowser', true)
%
% Points are time-ordered via navTrackTimeOrder. Web UI draws:
%   - Polyline trajectory
%   - Time-heat scatter (CustomOverlay dots when available)
%   - Start / end CustomOverlay labels
%   - Bottom-right info panel
%
% GNSS = WGS84; tiles = BD-09 (Convertor 1→5 or offline fallback).
% AK: config/BaidumapKey.txt (gitignored).

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

    if ~isempty(opt.keyFile)
        ak = loadBaiduMapKey(opt.keyFile);
    elseif isfield(settings, 'baiduMapKeyFile') && ~isempty(settings.baiduMapKeyFile)
        ak = loadBaiduMapKey(settings.baiduMapKeyFile);
    else
        ak = loadBaiduMapKey();
    end

    trk = navTrackTimeOrder(navSolutions, settings);
    if trk.n < 1
        warning('launchBaiduMapTrack:NoFixes', 'No valid lat/lon — skip Baidu Map UI.');
        outDir = '';
        return;
    end

    % Build track payload (WGS84); tNorm in [0,1] for heat colour
    t0 = trk.t(1);
    tSpan = max(trk.t(end) - t0, eps);
    pts = struct('lng', {}, 'lat', {}, 'h', {}, 'tMs', {}, 'tNorm', {});
    for i = 1:trk.n
        pts(i).lng = trk.lon(i); %#ok<AGROW>
        pts(i).lat = trk.lat(i);
        pts(i).h   = trk.h(i);
        pts(i).tMs = trk.t(i) * 1000;
        pts(i).tNorm = (trk.t(i) - t0) / tSpan;
    end

    track = struct();
    track.coord = 'WGS84';
    track.note = 'Convert WGS84->BD-09 with BMap.Convertor before display';
    track.navSolPeriodMs = trk.navSolPeriodMs;
    track.nPoints = trk.n;
    track.nRemovedJump = trk.nRemovedJump;
    track.maxSpeedMps = trk.maxSpeedMps;
    track.meanLat = trk.meanLat;
    track.meanLon = trk.meanLon;
    track.meanH = trk.meanH;
    track.tStartS = trk.tStart;
    track.tEndS = trk.tEnd;
    track.durationS = trk.tEnd - trk.tStart;
    track.start = struct('lng', trk.lon(1), 'lat', trk.lat(1), 'h', trk.h(1));
    track.end   = struct('lng', trk.lon(end), 'lat', trk.lat(end), 'h', trk.h(end));
    if any(isfinite(trk.GDOP))
        track.medianGDOP = median(trk.GDOP(isfinite(trk.GDOP)));
    else
        track.medianGDOP = NaN;
    end
    if any(isfinite(trk.HDOP))
        track.medianHDOP = median(trk.HDOP(isfinite(trk.HDOP)));
    else
        track.medianHDOP = NaN;
    end
    if any(isfinite(trk.VDOP))
        track.medianVDOP = median(trk.VDOP(isfinite(trk.VDOP)));
    else
        track.medianVDOP = NaN;
    end
    track.points = pts;

    jsonPath = fullfile(outDir, 'track.json');
    writeTrackJson(jsonPath, track);

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
    html = strrep(html, '{{TITLE}}', sprintf('B2a PVT track (N=%d)', trk.n));

    js = fileread(tplJs);

    htmlOut = fullfile(outDir, 'index.html');
    jsOut   = fullfile(outDir, 'track.js');
    writeTextFile(htmlOut, html);
    writeTextFile(jsOut, js);
    readmeSrc = fullfile(webTplDir, 'README.md');
    if isfile(readmeSrc)
        copyfile(readmeSrc, fullfile(outDir, 'README.md'));
    end

    fprintf('Baidu Map UI written: %s\n', htmlOut);
    fprintf('  points: %d  mean WGS84 (%.6f, %.6f)  start→end t=%.1f→%.1f s\n', ...
        trk.n, trk.meanLat, trk.meanLon, trk.tStart, trk.tEnd);
    fprintf('  NOTE: open via http://127.0.0.1 (not file://) so Baidu tiles load.\n');

    if opt.openBrowser
        openInBrowser(htmlOut, outDir);
    end
end

function writeTrackJson(path, track)
    try
        txt = jsonencode(track);
    catch
        n = track.nPoints;
        pts = cell(n, 1);
        for i = 1:n
            p = track.points(i);
            pts{i} = sprintf( ...
                '{"lng":%.8f,"lat":%.8f,"h":%.3f,"tMs":%g,"tNorm":%.6f}', ...
                p.lng, p.lat, p.h, p.tMs, p.tNorm);
        end
        txt = sprintf(['{"coord":"WGS84","nPoints":%d,"meanLat":%.8f,' ...
            '"meanLon":%.8f,"meanH":%.3f,"navSolPeriodMs":%g,"points":[%s]}'], ...
            n, track.meanLat, track.meanLon, track.meanH, ...
            track.navSolPeriodMs, strjoin(pts, ','));
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

function openInBrowser(htmlPath, outDir)
    htmlPath = char(htmlPath);
    if nargin < 2 || isempty(outDir)
        outDir = fileparts(htmlPath);
    end
    outDir = char(outDir);

    url = startLocalHttpAndUrl(outDir);
    if ~isempty(url)
        fprintf('  Open in browser: %s\n', url);
        try
            web(url, '-browser');
            return;
        catch
        end
        if ispc
            system(sprintf('start "" "%s"', url));
        elseif ismac
            system(sprintf('open "%s"', url));
        else
            system(sprintf('xdg-open "%s" &', url));
        end
        return;
    end

    warning('launchBaiduMapTrack:NoHttpServer', ...
        ['Could not start local HTTP server (need python/py). ' ...
         'Opening file:// — Baidu basemap often blank. ' ...
         'Manually: cd to output folder and run: python -m http.server 8765']);
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

function url = startLocalHttpAndUrl(outDir)
    url = '';
    ports = 8765:8775;
    py = localPythonCmd();
    if isempty(py)
        return;
    end
    for p = ports
        try
            t = webread(sprintf('http://127.0.0.1:%d/index.html', p), ...
                weboptions('Timeout', 0.4)); %#ok<NASGU>
            % Occupied by an unknown/older result directory. Never reuse it
            % for a new track because that can display the wrong job.
            continue;
        catch
        end
        try
            if ispc
                cmd = sprintf([ ...
                    'start "b2a-baidumap-%d" /min cmd /c ' ...
                    '"cd /d "%s" && %s -m http.server %d"'], ...
                    p, outDir, py, p);
                [st, ~] = system(cmd);
            else
                cmd = sprintf('cd "%s" && %s -m http.server %d >/dev/null 2>&1 &', ...
                    outDir, py, p);
                [st, ~] = system(cmd);
            end
            if st ~= 0
                continue;
            end
            pause(0.6);
            try
                t = webread(sprintf('http://127.0.0.1:%d/index.html', p), ...
                    weboptions('Timeout', 1.5)); %#ok<NASGU>
                url = sprintf('http://127.0.0.1:%d/index.html', p);
                return;
            catch
            end
        catch
        end
    end
end

function py = localPythonCmd()
    py = '';
    cands = {'python', 'py -3', 'py'};
    for i = 1:numel(cands)
        try
            [st, out] = system(sprintf('%s --version', cands{i}));
            if st == 0 && contains(lower(out), 'python')
                py = cands{i};
                return;
            end
        catch
        end
    end
end
