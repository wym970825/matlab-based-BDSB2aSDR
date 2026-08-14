function [pos, el, az, dop, info] = raimLeastSquarePos(satpos, obs, settings, prnList, weights)
%RAIMLEASTSQUAREPOS LS position with RAIM single/dual-SV fault exclusion.
%
%   [pos, el, az, dop, info] = raimLeastSquarePos(satpos, obs, settings, prnList)
%   [pos, el, az, dop, info] = raimLeastSquarePos(..., weights)
%
% Strategy (solution-separation FDE):
%   1) All-in-view least-squares
%   2) If integrity fails: try every single-SV exclusion (need n>=5)
%   3) If still fails: try every dual-SV exclusion (need n>=6)
%   4) Among candidates that pass residual + Earth-radius gates, pick the
%      one with smallest residual RMS (prefer fewer exclusions on ties)
%
% Integrity (default):
%   - residual RMS of used SVs <= raim.maxRmsM  (default 80 m)
%   - max |residual|            <= raim.maxResM (default 200 m)
%   - |r|_ECEF in [5.5e6, 7.5e6] m  (receiver near Earth surface)
%
% prnList: 1xN PRN numbers matching columns of satpos / obs (for logging).
% weights: optional 1xN observation weights (elev/C/N0 WLS); default ones.

    if nargin < 4 || isempty(prnList)
        prnList = 1:size(satpos, 2);
    end
    prnList = prnList(:).';
    n = size(satpos, 2);
    if numel(obs) ~= n
        error('raimLeastSquarePos:Size', 'obs length must match satpos columns');
    end
    obs = obs(:).';
    if nargin < 5 || isempty(weights)
        weights = ones(1, n);
    else
        weights = weights(:).';
        if numel(weights) ~= n
            error('raimLeastSquarePos:WeightSize', ...
                'weights length must match satpos columns');
        end
    end

    cfg = localRaimCfg(settings);

    info = struct();
    info.enabled = true;
    info.nSat = n;
    info.mode = 'fail';
    info.excludedIdx = [];
    info.excludedPRN = [];
    info.nExcluded = 0;
    info.usedPRN = prnList(:).';
    info.residualRms = inf;
    info.maxResidual = inf;
    info.passed = false;
    info.nTried = 0;

    el = nan(1, n);
    az = nan(1, n);
    dop = inf(1, 5);
    pos = nan(4, 1);

    if n < 4
        info.mode = 'too_few';
        return;
    end

    % Candidate list: {excludeIdx (row vector), label}
    cands = {};
    cands{end+1} = struct('ex', [], 'label', 'all'); %#ok<*AGROW>

    if cfg.enableFde1 && n >= 5
        for i = 1:n
            cands{end+1} = struct('ex', i, 'label', 'fde1');
        end
    end
    if cfg.enableFde2 && n >= 6
        for i = 1:n-1
            for j = i+1:n
                cands{end+1} = struct('ex', [i j], 'label', 'fde2');
            end
        end
    end

    bestScore = inf;
    best = [];

    for k = 1:numel(cands)
        ex = cands{k}.ex;
        keep = true(1, n);
        keep(ex) = false;
        if nnz(keep) < 4
            continue;
        end
        info.nTried = info.nTried + 1;

        try
            [p, elK, azK, dopK, resK] = leastSquarePos( ...
                satpos(:, keep), obs(keep).', settings, weights(keep));
        catch
            continue;
        end
        if isempty(p) || any(~isfinite(p(1:3)))
            continue;
        end
        p = p(:);
        if numel(p) < 4
            continue;
        end

        resK = resK(:);
        rmsK = sqrt(mean(resK.^2));
        maxK = max(abs(resK));
        earthR = norm(p(1:3));
        earthOk = earthR > cfg.earthRmin && earthR < cfg.earthRmax;
        resOk = isfinite(rmsK) && rmsK <= cfg.maxRmsM && maxK <= cfg.maxResM;

        % Soft score: always rank; hard gates for "passed"
        nEx = numel(ex);
        score = rmsK + 0.1 * maxK + 50 * nEx;
        if ~earthOk
            score = score + 1e7 + abs(earthR - 6.371e6);
        end
        if ~resOk
            score = score + 1e5 + max(0, rmsK - cfg.maxRmsM);
        end

        cand = struct();
        cand.pos = p;
        cand.dop = dopK;
        cand.elKeep = elK;
        cand.azKeep = azK;
        cand.resKeep = resK;
        cand.keep = keep;
        cand.ex = ex;
        cand.label = cands{k}.label;
        cand.rms = rmsK;
        cand.maxRes = maxK;
        cand.earthOk = earthOk;
        cand.resOk = resOk;
        cand.passed = earthOk && resOk;
        cand.score = score;

        if score < bestScore
            bestScore = score;
            best = cand;
        end

        % Early exit: all-in-view already good — still finished evaluating
        % only if cfg.alwaysSearch is false
        if k == 1 && cand.passed && ~cfg.alwaysSearch
            break;
        end
    end

    if isempty(best)
        info.mode = 'fail';
        return;
    end

    pos = best.pos;
    dop = best.dop;
    el(best.keep) = best.elKeep;
    az(best.keep) = best.azKeep;

    % Elev/az for excluded SVs from final position (display only)
    if any(~best.keep)
        exIdx = find(~best.keep);
        for ii = 1:numel(exIdx)
            i = exIdx(ii);
            try
                [az(i), el(i), ~] = topocent(pos(1:3), satpos(:, i) - pos(1:3));
            catch
                az(i) = NaN;
                el(i) = NaN;
            end
        end
    end

    info.mode = best.label;
    info.excludedIdx = best.ex;
    info.excludedPRN = prnList(best.ex).';
    info.nExcluded = numel(info.excludedPRN);
    info.usedPRN = prnList(best.keep).';
    info.residualRms = best.rms;
    info.maxResidual = best.maxRes;
    info.passed = best.passed;
    info.earthR = norm(pos(1:3));
end

function cfg = localRaimCfg(settings)
    cfg = struct();
    cfg.enableFde1 = true;
    cfg.enableFde2 = true;
    cfg.alwaysSearch = true;   % still try FDE if all-in-view looks OK? false faster
    cfg.maxRmsM = 80;          % residual RMS gate (m)
    cfg.maxResM = 200;         % max |residual| gate (m)
    cfg.earthRmin = 5.5e6;
    cfg.earthRmax = 7.5e6;

    if ~isfield(settings, 'raim') || isempty(settings.raim)
        return;
    end
    r = settings.raim;
    if isfield(r, 'enableFde1'),   cfg.enableFde1 = logical(r.enableFde1); end
    if isfield(r, 'enableFde2'),   cfg.enableFde2 = logical(r.enableFde2); end
    if isfield(r, 'alwaysSearch'), cfg.alwaysSearch = logical(r.alwaysSearch); end
    if isfield(r, 'maxRmsM') && isfinite(r.maxRmsM), cfg.maxRmsM = r.maxRmsM; end
    if isfield(r, 'maxResM') && isfinite(r.maxResM), cfg.maxResM = r.maxResM; end
    if isfield(r, 'earthRmin') && isfinite(r.earthRmin), cfg.earthRmin = r.earthRmin; end
    if isfield(r, 'earthRmax') && isfinite(r.earthRmax), cfg.earthRmax = r.earthRmax; end
end
