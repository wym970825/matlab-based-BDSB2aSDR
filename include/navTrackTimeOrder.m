function trk = navTrackTimeOrder(navSolutions, settings)
%NAVTRACKTIMEORDER Aggregate valid PVT fixes in chronological epoch order.
%
%   trk = navTrackTimeOrder(navSolutions, settings)
%
% Drops non-finite lat/lon; keeps original epoch order. Then removes points
% that imply an ENU velocity jump: any of |vE|,|vN|,|vU| >
% settings.navTrackMaxSpeedMps (default 500 m/s) between consecutive points.
%
% Used by plotNavPost / launchBaiduMapTrack so map and time series share
% the same filtered point list.
%
% Extra fields:
%   .nRemovedJump  - points removed by velocity-jump filter
%   .maxSpeedMps   - threshold used

    trk = struct('idx', [], 't', [], 'lat', [], 'lon', [], 'h', [], ...
        'E', [], 'N', [], 'U', [], ...
        'GDOP', [], 'PDOP', [], 'HDOP', [], 'VDOP', [], 'TDOP', [], ...
        'n', 0, 'tStart', NaN, 'tEnd', NaN, ...
        'meanLat', NaN, 'meanLon', NaN, 'meanH', NaN, ...
        'navSolPeriodMs', 500, 'nRemovedJump', 0, 'maxSpeedMps', 500);

    if isempty(navSolutions) || ~isfield(navSolutions, 'latitude')
        return;
    end

    periodMs = 500;
    if nargin >= 2 && isstruct(settings) && isfield(settings, 'navSolPeriod') ...
            && ~isempty(settings.navSolPeriod)
        periodMs = settings.navSolPeriod;
    end
    trk.navSolPeriodMs = periodMs;

    vMax = 500;
    if nargin >= 2 && isstruct(settings) && isfield(settings, 'navTrackMaxSpeedMps') ...
            && ~isempty(settings.navTrackMaxSpeedMps) ...
            && isfinite(settings.navTrackMaxSpeedMps) ...
            && settings.navTrackMaxSpeedMps > 0
        vMax = settings.navTrackMaxSpeedMps;
    end
    trk.maxSpeedMps = vMax;

    lat = navSolutions.latitude(:);
    lon = navSolutions.longitude(:);
    nEp = numel(lat);
    if nEp < 1
        return;
    end

    h = nan(nEp, 1);
    if isfield(navSolutions, 'height') && ~isempty(navSolutions.height)
        hh = navSolutions.height(:);
        h(1:min(nEp, numel(hh))) = hh(1:min(nEp, numel(hh)));
    end
    E = nan(nEp, 1); N = nan(nEp, 1); U = nan(nEp, 1);
    if isfield(navSolutions, 'E'), E = padVec(navSolutions.E, nEp); end
    if isfield(navSolutions, 'N'), N = padVec(navSolutions.N, nEp); end
    if isfield(navSolutions, 'U'), U = padVec(navSolutions.U, nEp); end

    ok = isfinite(lat) & isfinite(lon);
    idx = find(ok); % already chronological
    if isempty(idx)
        return;
    end

    tAll = (0:nEp-1)' * (periodMs / 1000);
    trk.idx = idx(:);
    trk.t   = tAll(idx);
    trk.lat = lat(idx);
    trk.lon = lon(idx);
    trk.h   = h(idx);
    trk.E   = E(idx);
    trk.N   = N(idx);
    trk.U   = U(idx);

    gdop = nan(nEp, 1); pdop = gdop; hdop = gdop; vdop = gdop; tdop = gdop;
    if isfield(navSolutions, 'DOP') && ~isempty(navSolutions.DOP)
        D = navSolutions.DOP;
        if size(D, 1) >= 1, gdop = padVec(D(1, :), nEp); end
        if size(D, 1) >= 2, pdop = padVec(D(2, :), nEp); end
        if size(D, 1) >= 3, hdop = padVec(D(3, :), nEp); end
        if size(D, 1) >= 4, vdop = padVec(D(4, :), nEp); end
        if size(D, 1) >= 5, tdop = padVec(D(5, :), nEp); end
    end
    trk.GDOP = gdop(idx);
    trk.PDOP = pdop(idx);
    trk.HDOP = hdop(idx);
    trk.VDOP = vdop(idx);
    trk.TDOP = tdop(idx);

    nBefore = numel(trk.idx);
    trk = removeEnuVelocityJumps(trk, vMax);
    trk.nRemovedJump = nBefore - numel(trk.idx);
    trk = refreshTrackStats(trk);

    if trk.nRemovedJump > 0
        fprintf(['navTrackTimeOrder: removed %d jump point(s) ' ...
            '(|vE| or |vN| or |vU| > %.0f m/s); kept %d\n'], ...
            trk.nRemovedJump, vMax, trk.n);
    end
end

function trk = removeEnuVelocityJumps(trk, vMax)
% Iteratively drop the *later* point of any consecutive pair whose ENU
% velocity exceeds vMax in any component (position jump).
    if numel(trk.t) < 2
        return;
    end

    maxIter = max(10, numel(trk.t));
    for it = 1:maxIter
        n = numel(trk.t);
        if n < 2
            break;
        end
        [e, nE, u] = localEnuMeters(trk);
        drop = false(n, 1);
        for i = 1:n-1
            dt = trk.t(i+1) - trk.t(i);
            if ~(isfinite(dt) && dt > 0)
                drop(i+1) = true;
                continue;
            end
            if ~all(isfinite([e(i), e(i+1), nE(i), nE(i+1), u(i), u(i+1)]))
                continue;
            end
            vE = (e(i+1) - e(i)) / dt;
            vN = (nE(i+1) - nE(i)) / dt;
            vU = (u(i+1) - u(i)) / dt;
            if max([abs(vE), abs(vN), abs(vU)]) > vMax
                drop(i+1) = true; % discard jump landing
            end
        end
        if ~any(drop)
            break;
        end
        keep = ~drop;
        trk = subsetTrack(trk, keep);
    end
end

function [e, nE, u] = localEnuMeters(trk)
% Prefer UTM ENU; if missing, approximate from lat/lon/h about first fix.
    e  = trk.E(:);
    nE = trk.N(:);
    u  = trk.U(:);
    needApprox = ~all(isfinite(e) & isfinite(nE) & isfinite(u));
    if ~needApprox
        return;
    end
    lat0 = trk.lat(1) * pi/180;
    mPerDegLat = 111320;
    mPerDegLon = 111320 * cos(lat0);
    eA  = (trk.lon(:) - trk.lon(1)) * mPerDegLon;
    nA  = (trk.lat(:) - trk.lat(1)) * mPerDegLat;
    uA  = trk.h(:) - trk.h(1);
    uA(~isfinite(uA)) = 0;
    bad = ~isfinite(e) | ~isfinite(nE) | ~isfinite(u);
    e(bad)  = eA(bad);
    nE(bad) = nA(bad);
    u(bad)  = uA(bad);
end

function trk = subsetTrack(trk, keep)
    fn = {'idx','t','lat','lon','h','E','N','U','GDOP','PDOP','HDOP','VDOP','TDOP'};
    for k = 1:numel(fn)
        f = fn{k};
        if isfield(trk, f) && ~isempty(trk.(f))
            v = trk.(f)(:);
            trk.(f) = v(keep);
        end
    end
end

function trk = refreshTrackStats(trk)
    trk.n = numel(trk.t);
    if trk.n < 1
        trk.tStart = NaN;
        trk.tEnd = NaN;
        trk.meanLat = NaN;
        trk.meanLon = NaN;
        trk.meanH = NaN;
        return;
    end
    trk.tStart = trk.t(1);
    trk.tEnd   = trk.t(end);
    trk.meanLat = mean(trk.lat);
    trk.meanLon = mean(trk.lon);
    hh = trk.h(isfinite(trk.h));
    if isempty(hh), trk.meanH = NaN; else, trk.meanH = mean(hh); end
end

function v = padVec(x, n)
    x = x(:);
    v = nan(n, 1);
    m = min(n, numel(x));
    v(1:m) = x(1:m);
end
