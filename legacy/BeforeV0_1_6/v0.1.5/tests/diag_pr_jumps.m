function diag_pr_jumps(matPath)
%DIAG_PR_JUMPS Analyse large pseudorange steps in a saved fullsky report.
%
%   diag_pr_jumps()
%   diag_pr_jumps('results/smoke/fullsky_pvt60_260730_210230/results.mat')

    setupPaths();
    if nargin < 1 || isempty(matPath)
        matPath = fullfile('results', 'smoke', 'fullsky_pvt60_260730_210230', 'results.mat');
    end
    assert(isfile(matPath), 'mat not found: %s', matPath);

    S = load(matPath);
    if isfield(S, 'report')
        r = S.report;
    else
        r = S;
    end
    ns = r.navSolutions;
    tr = r.trackResults;
    settings = r.settings;
    Tms = settings.navSolPeriod;
    nEp = numel(ns.X);
    t_s = (0:nEp-1) * Tms / 1000;

    fprintf('=== PR jump diagnosis ===\n');
    fprintf('file: %s\n', matPath);
    fprintf('epochs=%d  navSolPeriod=%g ms  channels=%d\n', nEp, Tms, numel(tr));

    % ---- rawP step stats per channel (aligned by PRN column) ----
    rawP = ns.rawP;          % nCh x nEp
    corrP = [];
    if isfield(ns, 'correctedP'), corrP = ns.correctedP; end
    tt = [];
    if isfield(ns, 'transmitTime'), tt = ns.transmitTime; end
    prnMat = ns.PRN;

    nCh = size(rawP, 1);
    thrM = 1e4;   % 10 km step
    thrMild = 500; % 500 m

    fprintf('\n--- Epoch-to-epoch |d(rawP)| > %.0f m ---\n', thrM);
    jumpLog = [];
    for ch = 1:nCh
        prnRow = prnMat(ch, :);
        prn = localModePrn(prnRow);
        if isempty(prn) || ~isfinite(prn) || prn == 0
            continue;
        end
        rp = rawP(ch, :);
        for e = 2:nEp
            if ~isfinite(rp(e)) || ~isfinite(rp(e-1)), continue; end
            d = rp(e) - rp(e-1);
            if abs(d) >= thrMild
                jumpLog = [jumpLog; ch, prn, e-1, e, t_s(e), d, rp(e-1), rp(e)]; %#ok<AGROW>
            end
        end
    end

    if isempty(jumpLog)
        fprintf('No |d(rawP)| >= %.0f m found.\n', thrMild);
    else
        % Sort by |d|
        [~, ix] = sort(abs(jumpLog(:,6)), 'descend');
        jumpLog = jumpLog(ix, :);
        nShow = min(40, size(jumpLog, 1));
        fprintf('Found %d mild+ jumps; top %d by |d|:\n', size(jumpLog,1), nShow);
        fprintf('%4s %5s %6s %8s %12s %14s %14s %14s\n', ...
            'ch', 'PRN', 'ep', 't_s', 'd_rawP_m', 'rawP_prev', 'rawP_now', 'nChips');
        for i = 1:nShow
            d = jumpLog(i,6);
            nChip = d / settings.c * settings.codeFreqBasis; % m -> s -> chips
            fprintf('%4d %5d %6d %8.1f %12.1f %14.1f %14.1f %14.2f\n', ...
                jumpLog(i,1), jumpLog(i,2), jumpLog(i,4), jumpLog(i,5), ...
                d, jumpLog(i,7), jumpLog(i,8), nChip);
        end
    end

    % Per-PRN max step
    fprintf('\n--- Per-PRN max |d(rawP)| ---\n');
    uPrn = unique(jumpLog(:,2));
    if isempty(jumpLog), uPrn = []; end
    allPrn = unique(prnMat(prnMat > 0));
    for p = allPrn(:).'
        if isempty(jumpLog)
            m = 0; nJ = 0;
        else
            msk = jumpLog(:,2) == p;
            if any(msk)
                m = max(abs(jumpLog(msk,6)));
                nJ = sum(msk);
            else
                m = 0; nJ = 0;
            end
        end
        % also scan all steps including small
        chs = find(any(prnMat == p, 2));
        maxAll = 0; maxEp = 0;
        for ch = chs(:).'
            rp = rawP(ch,:);
            d = diff(rp);
            d = d(isfinite(d));
            if ~isempty(d)
                [mm, ii] = max(abs(d));
                if mm > maxAll
                    maxAll = mm;
                    maxEp = ii + 1;
                end
            end
        end
        fprintf('  PRN%02d  max|dP|=%10.1f m  (@ep~%d t=%.1fs)  mildJumps=%d\n', ...
            p, maxAll, maxEp, (maxEp-1)*Tms/1000, nJ);
    end

    % ---- Align jumps with tracking state / REACQ / CNo ----
    fprintf('\n--- Tracking state near large jumps (|dP|>=10 km) ---\n');
    big = [];
    if ~isempty(jumpLog)
        big = jumpLog(abs(jumpLog(:,6)) >= thrM, :);
    end
    if isempty(big)
        fprintf('No |dP|>=10 km jumps.\n');
    else
        for i = 1:min(20, size(big,1))
            ch = big(i,1); prn = big(i,2); ep = big(i,4); t = big(i,5); d = big(i,6);
            fprintf('\nJUMP PRN%02d ch%d ep%d t=%.1fs dP=%.1f m (%.2f chips, %.3f ms light)\n', ...
                prn, ch, ep, t, d, d/settings.c*settings.codeFreqBasis, d/settings.c*1e3);
            % find trackResults index for PRN
            kTr = find([tr.PRN] == prn, 1);
            if isempty(kTr)
                fprintf('  (no trackResults for PRN)\n');
                continue;
            end
            % ms index around t
            ms0 = max(1, round(t*1000) - 50);
            ms1 = min(numel(tr(kTr).cur_state), round(t*1000) + 50);
            st = tr(kTr).cur_state(ms0:ms1);
            fprintf('  cur_state ms[%d:%d]: min=%d max=%d mean=%.2f unique=%s\n', ...
                ms0, ms1, min(st), max(st), mean(double(st)), mat2str(unique(st(:).')));
            if isfield(tr, 'B2a_CNo') || isfield(tr(kTr), 'B2a_CNo')
                cno = tr(kTr).B2a_CNo;
                % CNo is usually every CNoInterval ms
                if ~isempty(cno)
                    ci = settings.CNoInterval;
                    i0 = max(1, floor(ms0/ci)); i1 = min(numel(cno), ceil(ms1/ci));
                    fprintf('  CNo[%d:%d]=%s\n', i0, i1, mat2str(cno(i0:i1), 3));
                end
            end
            % transmitTime step if available
            if ~isempty(tt)
                dtt = tt(ch, ep) - tt(ch, ep-1);
                fprintf('  d(transmitTime)=%.6f s  (expect ~%.3f s)\n', dtt, Tms/1000);
            end
            if ~isempty(corrP)
                dcp = corrP(ch, ep) - corrP(ch, ep-1);
                fprintf('  d(correctedP)=%.1f m\n', dcp);
            end
            % REACQ markers if present
            for fn = {'reacqFlag', 'REACQ', 'stateLog', 'lockLost'}
                if isfield(tr(kTr), fn{1})
                    fprintf('  field %s present\n', fn{1});
                end
            end
            % codeFreq / carrFreq discontinuity near that ms
            if isfield(tr(kTr), 'codeFreq')
                cf = tr(kTr).codeFreq;
                idx = max(2, min(numel(cf), round(t*1000)));
                w = max(1, idx-5):min(numel(cf), idx+5);
                dcf = max(abs(diff(cf(w))));
                fprintf('  codeFreq near ms%d: max|d|=%.3f Hz  values=%s\n', ...
                    idx, dcf, mat2str(cf(w), 4));
            end
            if isfield(tr(kTr), 'carrFreq')
                cf = tr(kTr).carrFreq;
                idx = max(2, min(numel(cf), round(t*1000)));
                w = max(1, idx-5):min(numel(cf), idx+5);
                fprintf('  carrFreq near ms%d: %s\n', idx, mat2str(cf(w), 4));
            end
            if isfield(tr(kTr), 'absoluteSample')
                as = tr(kTr).absoluteSample;
                idx = max(2, min(numel(as), round(t*1000)));
                w = max(1, idx-3):min(numel(as), idx+3);
                das = diff(double(as(w)));
                fprintf('  absoluteSample step near ms%d: %s (nominal ~%g)\n', ...
                    idx, mat2str(das, 6), settings.samplingFreq*0.001);
            end
        end
    end

    % ---- RAIM exclusion correlation ----
    if isfield(ns, 'raim') && isfield(ns.raim, 'excludedPRN')
        fprintf('\n--- RAIM exclusions around big PR jumps ---\n');
        for i = 1:min(15, size(big,1))
            ep = big(i,4); prn = big(i,2);
            ex = ns.raim.excludedPRN{ep};
            mode = '';
            if isfield(ns.raim, 'mode'), mode = ns.raim.mode{ep}; end
            rms = NaN;
            if isfield(ns.raim, 'residualRms'), rms = ns.raim.residualRms(ep); end
            fprintf('  ep%d t=%.1fs PRN%d dP=%.0fm  raim=%s ex=%s rms=%.1f\n', ...
                ep, t_s(ep), prn, big(i,6), mode, mat2str(ex), rms);
        end
        % Count exclusions per PRN
        exAll = [ns.raim.excludedPRN{:}];
        if ~isempty(exAll)
            u = unique(exAll);
            fprintf('RAIM exclude counts: ');
            for p = u
                fprintf('PRN%d=%d ', p, sum(exAll==p));
            end
            fprintf('\n');
        end
    end

    % ---- Height / LLA vs jump epochs ----
    if isfield(ns, 'height')
        h = ns.height;
        fprintf('\n--- Height timeline (suspect segments) ---\n');
        fprintf('  h finite=%d  mean=%.1f  min=%.1f max=%.1f\n', ...
            sum(isfinite(h)), mean(h(isfinite(h))), min(h(isfinite(h))), max(h(isfinite(h))));
        badH = isfinite(h) & abs(h) > 5000;
        fprintf('  |h|>5km epochs: %d\n', sum(badH));
        if any(badH)
            ib = find(badH);
            fprintf('  first badH ep=%d t=%.1fs h=%.1f  last ep=%d t=%.1fs h=%.1f\n', ...
                ib(1), t_s(ib(1)), h(ib(1)), ib(end), t_s(ib(end)), h(ib(end)));
        end
    end

    % ---- transmitTime continuity (all channels) ----
    if ~isempty(tt)
        fprintf('\n--- transmitTime steps far from %.3f s ---\n', Tms/1000);
        expDt = Tms/1000;
        nBad = 0;
        for ch = 1:size(tt,1)
            prnRow = prnMat(ch,:);
            prn = localModePrn(prnRow);
            if isempty(prn) || prn==0, continue; end
            for e = 2:nEp
                if ~isfinite(tt(ch,e)) || ~isfinite(tt(ch,e-1)), continue; end
                dtt = tt(ch,e) - tt(ch,e-1);
                if abs(dtt - expDt) > 0.05  % >50 ms anomaly
                    nBad = nBad + 1;
                    if nBad <= 25
                        dChip = (dtt - expDt) * settings.codeFreqBasis;
                        fprintf('  PRN%02d ep%d t=%.1fs dtt=%.6fs (exp %.3f) dChip=%.1f\n', ...
                            prn, e, t_s(e), dtt, expDt, dChip);
                    end
                end
            end
        end
        fprintf('  total transmitTime anomalies: %d\n', nBad);
    end

    % ---- localTime ----
    if isfield(ns, 'localTime')
        lt = ns.localTime;
        dlt = diff(lt);
        fprintf('\n--- localTime ---\n');
        fprintf('  d(localTime) mean=%.6f min=%.6f max=%.6f (expect %.3f)\n', ...
            mean(dlt(isfinite(dlt))), min(dlt(isfinite(dlt))), max(dlt(isfinite(dlt))), Tms/1000);
        badLt = find(isfinite(dlt) & abs(dlt - Tms/1000) > 0.05);
        fprintf('  |dlt-period|>50ms count=%d\n', numel(badLt));
        if ~isempty(badLt)
            for i = 1:min(10, numel(badLt))
                e = badLt(i)+1;
                fprintf('    ep%d t=%.1fs dlt=%.6f dt_m=%.1f\n', e, t_s(e), dlt(e-1), ns.dt(e));
            end
        end
    end

    fprintf('\n=== done ===\n');
end

function p = localModePrn(prnRow)
    v = prnRow(prnRow > 0 & isfinite(prnRow));
    if isempty(v)
        p = 0;
        return;
    end
    uv = unique(v);
    cnt = arrayfun(@(x) sum(v == x), uv);
    [~, i] = max(cnt);
    p = uv(i);
end
