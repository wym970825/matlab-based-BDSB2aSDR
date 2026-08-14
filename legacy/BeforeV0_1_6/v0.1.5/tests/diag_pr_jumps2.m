function diag_pr_jumps2(matPath)
%DIAG_PR_JUMPS2 Deep-dive: clock vs transmitTime vs absoluteSample around PR jumps.

    setupPaths();
    if nargin < 1 || isempty(matPath)
        matPath = fullfile('results', 'smoke', 'fullsky_pvt60_260730_210230', 'results.mat');
    end
    S = load(matPath);
    r = S.report;
    ns = r.navSolutions;
    tr = r.trackResults;
    settings = r.settings;
    c = settings.c;
    fs = settings.samplingFreq;
    Tms = settings.navSolPeriod;
    nEp = numel(ns.X);
    t_s = (0:nEp-1) * Tms / 1000;

    fprintf('=== Deep PR jump analysis ===\n');

    % --- Epoch 1 vs 2: common clock ---
    fprintf('\n--- Epoch1->2 (common-mode / first-fix clock) ---\n');
    fprintf('  dt(1)=%.1f m  dt(2)=%.1f m\n', ns.dt(1), ns.dt(2));
    fprintf('  localTime(1)=%.6f  localTime(2)=%.6f  d=%.6f s\n', ...
        ns.localTime(1), ns.localTime(2), ns.localTime(2)-ns.localTime(1));
    dRaw = ns.rawP(:,2) - ns.rawP(:,1);
    dCorr = ns.correctedP(:,2) - ns.correctedP(:,1);
    dTt = ns.transmitTime(:,2) - ns.transmitTime(:,1);
    fprintf('  rawP d (all ch): mean=%.1f min=%.1f max=%.1f m  (%.3f ms light)\n', ...
        mean(dRaw), min(dRaw), max(dRaw), mean(dRaw)/c*1e3);
    fprintf('  correctedP d: mean=%.1f min=%.1f max=%.1f m\n', mean(dCorr), min(dCorr), max(dCorr));
    fprintf('  transmitTime d: mean=%.6f min=%.6f max=%.6f s\n', mean(dTt), min(dTt), max(dTt));
    fprintf('  Interpretation: if rawP common jump >> correctedP scatter, cause is localTime/dt reset after fix1.\n');

    % --- Scan transmitTime anomalies vs PR jumps 160-180s ---
    fprintf('\n--- Window t=160..180 s ---\n');
    e0 = find(t_s >= 160, 1);
    e1 = find(t_s <= 180, 1, 'last');
    fprintf('  epochs %d..%d\n', e0, e1);

    fprintf('\n  localTime / dt in window:\n');
    for e = e0:e1
        if e == 1, continue; end
        dlt = ns.localTime(e) - ns.localTime(e-1);
        if abs(dlt - Tms/1000) > 0.001 || abs(ns.dt(e)) > 1e4
            fprintf('    ep%3d t=%6.1f  dlt=%.6fs  dt=%.1fm  h=%.1f  raim=%s\n', ...
                e, t_s(e), dlt, ns.dt(e), ns.height(e), ns.raim.mode{e});
        end
    end

    fprintf('\n  Per-channel transmitTime vs rawP (only |dP|>30km or |dtt-0.5|>1ms):\n');
    for ch = 1:size(ns.rawP,1)
        prn = ns.PRN(ch, e0);
        fprintf('  -- ch%d PRN%02d --\n', ch, prn);
        for e = e0:e1
            dP = ns.rawP(ch,e) - ns.rawP(ch,e-1);
            dtt = ns.transmitTime(ch,e) - ns.transmitTime(ch,e-1);
            dcp = ns.correctedP(ch,e) - ns.correctedP(ch,e-1);
            if abs(dP) > 3e4 || abs(dtt - Tms/1000) > 0.001
                % expected dP from dtt and d(localTime)
                dlt = ns.localTime(e) - ns.localTime(e-1);
                dP_pred = (dlt - dtt) * c;
                fprintf(['    ep%3d t=%6.1f dP=%10.1f dPpred=%10.1f dtt=%.6f ' ...
                    'dlt=%.6f dCorr=%10.1f dt=%.1f\n'], ...
                    e, t_s(e), dP, dP_pred, dtt, dlt, dcp, ns.dt(e));
            end
        end
    end

    % --- absoluteSample continuity near 165s for each PRN ---
    fprintf('\n--- absoluteSample / codeFreq around t=165s (ms 164000..166000) ---\n');
    for k = 1:numel(tr)
        prn = tr(k).PRN;
        if prn == 0, continue; end
        as = double(tr(k).absoluteSample(:));
        n = numel(as);
        i0 = max(2, min(n, 164000));
        i1 = max(i0, min(n, 166000));
        das = diff(as(i0:i1));
        nom = fs * 0.001;
        bad = find(abs(das - nom) > nom * 0.05);
        fprintf('  PRN%02d as[%d:%d] meanStep=%.1f nom=%.1f  |step-nom|>5%% count=%d\n', ...
            prn, i0, i1, mean(das), nom, numel(bad));
        if ~isempty(bad)
            for j = 1:min(8, numel(bad))
                ii = i0 + bad(j) - 1;
                fprintf('    ms%d step=%.1f (%.3f ms) as=%g->%g\n', ...
                    ii, das(bad(j)), das(bad(j))/fs*1e3, as(ii), as(ii+1));
            end
        end
        % largest as gaps whole track
        dasAll = diff(as);
        [mx, im] = max(abs(dasAll - nom));
        fprintf('    worst |step-nom|=%.1f samples (%.3f ms) at ms%d\n', ...
            mx, (dasAll(im)-nom)/fs*1e3, im);
    end

    % --- REACQ / state flips ---
    fprintf('\n--- LONG/INIT transitions (cur_state 0<->1) ---\n');
    for k = 1:numel(tr)
        prn = tr(k).PRN;
        if prn == 0, continue; end
        st = double(tr(k).cur_state(:));
        d = diff(st);
        flips = find(d ~= 0);
        fprintf('  PRN%02d state flips=%d', prn, numel(flips));
        if ~isempty(flips)
            show = flips(1:min(12, numel(flips)));
            fprintf(' at ms: %s', mat2str(show(:).'));
            % convert to approx nav epoch
            epApprox = 1 + floor(show / Tms);
            fprintf(' (~ep %s)', mat2str(epApprox(:).'));
        end
        fprintf('\n');
    end

    % --- Relative PR (remove common mode) ---
    fprintf('\n--- Relative rawP (remove epoch mean) max step ---\n');
    rel = ns.rawP - mean(ns.rawP, 1, 'omitnan');
    for ch = 1:size(rel,1)
        prn = ns.PRN(ch,1);
        d = diff(rel(ch,:));
        [mx, im] = max(abs(d));
        fprintf('  PRN%02d max|d(relP)|=%10.1f m at ep%d t=%.1fs\n', ...
            prn, mx, im+1, t_s(im+1));
    end

    % --- Summary physics ---
    fprintf('\n=== Physics summary ===\n');
    fprintf('1) Epoch1->2: all-SV rawP +~1.39e6 m (~4.63 ms*c) with d(tt)~0.5s, d(corrP)~hundreds m\n');
    fprintf('   => common localTime correction after first LS clock (SoftGNSS first dt forced 0).\n');
    fprintf('2) t~165s cluster: staggered ~0.45 ms transmitTime steps => ~134 km rawP drops.\n');
    fprintf('   => check absoluteSample gaps / code-index slips / REACQ in that window.\n');
    fprintf('3) If relP (de-meaned) jumps are small, fault is receiver clock; if large, SV-specific.\n');
end
