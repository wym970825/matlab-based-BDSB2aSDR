function run_trk100s_smoke()
%RUN_TRK100S_SMOKE PRN41, 100 s tracking smoke + chunk-merge checks + figures.
%   Re-run after TrackResults2 chunk fixes to confirm final arrays cover 0..100 s.

    setupPaths();
    prn = 41;
    ms  = 100000;

    stamp = string(datetime('now'), 'yyMMdd_HHmmss');
    outDir = fullfile(fileparts(mfilename('fullpath')), '..', 'results', 'smoke', ...
        sprintf('trk100s_%s', stamp));
    outDir = char(java.io.File(outDir).getCanonicalPath());
    figDir = fullfile(outDir, 'figures');
    if ~exist(figDir, 'dir'), mkdir(figDir); end

    fprintf('=== 100s single-SV smoke ===\nPRN=%d msToProcess=%d\noutDir=%s\n', prn, ms, outDir);

    smoke = smoke_tracking( ...
        'acqSatelliteList', prn, ...
        'msToProcess', ms, ...
        'doQuickPlot', false);

    tr = smoke.trackResults(1);
    nIp = numel(tr.I_P);
    nCs = numel(tr.cur_state);
    nTs = numel(tr.trk_state);

    % --- chunk-merge / coverage checks ---
    cno = tr.B2a_CNo;
    cnoOk = cno(isfinite(cno));
    if isempty(cnoOk)
        meanCNo = NaN; maxCNo = NaN;
    else
        meanCNo = mean(cnoOk); maxCNo = max(cnoOk);
    end

    nPre60  = min(60000, nCs);
    nPost60 = min(nCs, ms);
    longPre  = mean(tr.cur_state(1:nPre60)) * 100;
    longAll  = mean(tr.cur_state(1:min(nCs, ms))) * 100;
    postHasLong = false;
    if nPost60 > 60000
        postHasLong = any(tr.cur_state(60001:nPost60));
        longPost = mean(tr.cur_state(60001:nPost60)) * 100;
    else
        longPost = NaN;
    end

    nFiniteIp = nnz(isfinite(tr.I_P(1:min(nIp, ms))));
    nFiniteCarr = nnz(isfinite(tr.carrFreq(1:min(numel(tr.carrFreq), ms))));

    % Assert coverage after chunk fix
    okLen   = (nIp >= ms) || (isprop(tr,'Nsize') && tr.Nsize >= ms);
    okFill  = nFiniteIp > 0.9 * ms;
    okPost  = (nPost60 <= 60000) || postHasLong;
    okLong  = longAll > 50;  % should be well above old ~60% if whole 100s is LONG-heavy

    fprintf('\n--- coverage ---\n');
    fprintf('I_P length=%d  cur_state length=%d  trk_state length=%d\n', nIp, nCs, nTs);
    fprintf('finite I_P in 1..%d: %d (%.1f%%)\n', ms, nFiniteIp, 100*nFiniteIp/ms);
    fprintf('finite carrFreq: %d\n', nFiniteCarr);
    fprintf('LONG%% pre60=%.1f  post60=%.1f  all=%.1f  postHasLong=%d\n', ...
        longPre, longPost, longAll, postHasLong);
    fprintf('mean/max CNo=%.2f / %.2f\n', meanCNo, maxCNo);
    fprintf('track wall s=%.2f  status=%s  PRN=%d\n', smoke.elapsed_s, tr.status, tr.PRN);
    fprintf('CHECKS: okLen=%d okFill=%d okPost=%d okLong=%d\n', okLen, okFill, okPost, okLong);

    if okLen && okFill && okPost
        verdict = 'PASS';
    else
        verdict = 'FAIL';
    end
    fprintf('VERDICT: %s\n', verdict);

    % --- figures ---
    t = (1:min(nIp, ms)) / 1000;
    ip = tr.I_P(1:numel(t));
    qp = tr.Q_P(1:numel(t));
    pip = tr.Pilot_I_P(1:numel(t));
    pqp = tr.Pilot_Q_P(1:numel(t));
    cf  = tr.carrFreq(1:min(numel(tr.carrFreq), numel(t)));
    if numel(cf) < numel(t), cf(end+1:numel(t)) = NaN; end
    cs  = double(tr.cur_state(1:min(nCs, numel(t))));
    ts  = double(tr.trk_state(1:min(nTs, numel(t))));

    % Overview
    f1 = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1200 900]);
    subplot(4,1,1);
    plot(t, pip.^2 + pqp.^2, 'b'); grid on;
    ylabel('Pilot |P|^2'); title(sprintf('PRN %d 100s overview (%s)', tr.PRN, verdict));
    xlim([0 max(t)]);
    subplot(4,1,2);
    plot(t, ip.^2 + qp.^2, 'r'); grid on;
    ylabel('Data |P|^2'); xlim([0 max(t)]);
    subplot(4,1,3);
    plot(t, cf, 'k'); grid on;
    ylabel('carrFreq Hz'); xlim([0 max(t)]);
    subplot(4,1,4);
    yyaxis left; plot(t, cs, 'g'); ylabel('cur\_state'); ylim([-0.1 1.1]);
    yyaxis right; plot(t, ts, 'm'); ylabel('trk\_state');
    xlabel('t (s)'); xlim([0 max(t)]); grid on;
    exportgraphics(f1, fullfile(figDir, 'trk_overview.png'), 'Resolution', 150);
    close(f1);

    % Zoom last 10 s (critical: should NOT be empty after fix)
    i0 = max(1, numel(t) - 10000 + 1);
    tz = t(i0:end);
    f2 = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1100 700]);
    subplot(3,1,1);
    plot(tz, pip(i0:end).^2 + pqp(i0:end).^2); grid on;
    title(sprintf('Zoom last ~10 s (%.1f–%.1f s)', tz(1), tz(end)));
    ylabel('Pilot |P|^2');
    subplot(3,1,2);
    plot(tz, cf(i0:end)); grid on; ylabel('carrFreq');
    subplot(3,1,3);
    plot(tz, cs(i0:end), 'g'); hold on; plot(tz, ts(i0:end)/max(1,max(ts)), 'm');
    legend('cur\_state', 'trk\_state (scaled)'); grid on; xlabel('t (s)');
    exportgraphics(f2, fullfile(figDir, 'trk_zoom10s.png'), 'Resolution', 150);
    close(f2);

    % FLL / state / scint-ish panel
    f3 = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1100 700]);
    subplot(3,1,1);
    if isprop(tr, 'fllDiscrHz') && ~isempty(tr.fllDiscrHz)
        nf = min(numel(tr.fllDiscrHz), numel(t));
        plot(t(1:nf), tr.fllDiscrHz(1:nf));
    else
        plot(t, NaN(size(t)));
    end
    grid on; ylabel('fllDiscr Hz'); title('FLL / state / S4');
    subplot(3,1,2);
    plot(t, cs, 'g'); hold on; plot(t, ts, 'm');
    legend('cur\_state','trk\_state'); grid on; ylabel('state');
    subplot(3,1,3);
    if isprop(tr, 'S4') && ~isempty(tr.S4)
        s4 = tr.S4; s4 = s4(isfinite(s4));
        if ~isempty(s4)
            tc = (1:numel(s4)) * (smoke.settings.CNoInterval/1000);
            plot(tc, s4); grid on; ylabel('S4'); xlabel('t (s)');
        else
            plot(t, NaN(size(t))); ylabel('S4 (empty)');
        end
    else
        plot(t, NaN(size(t))); ylabel('S4 (n/a)');
    end
    exportgraphics(f3, fullfile(figDir, 'trk_fll_state_scint.png'), 'Resolution', 150);
    close(f3);

    % --- save ---
    smoke100 = smoke;
    smoke100.checks = struct( ...
        'okLen', okLen, 'okFill', okFill, 'okPost', okPost, 'okLong', okLong, ...
        'nIp', nIp, 'nFiniteIp', nFiniteIp, ...
        'longPre', longPre, 'longPost', longPost, 'longAll', longAll, ...
        'postHasLong', postHasLong, 'verdict', verdict, ...
        'meanCNo', meanCNo, 'maxCNo', maxCNo, 'elapsed_s', smoke.elapsed_s);
    save(fullfile(outDir, 'smoke100.mat'), 'smoke100', '-v7.3');

    fid = fopen(fullfile(outDir, 'summary.txt'), 'w');
    fprintf(fid, 'PRN %d\n', tr.PRN);
    fprintf(fid, 'msToProcess %d\n', ms);
    fprintf(fid, 'track wall s: %.2f\n', smoke.elapsed_s);
    fprintf(fid, 'mean/max CNo: %.2f / %.2f\n', meanCNo, maxCNo);
    fprintf(fid, 'LONG pct all: %.1f  pre60: %.1f  post60: %.1f\n', longAll, longPre, longPost);
    fprintf(fid, 'I_P len: %d  finite: %d  postHasLong: %d\n', nIp, nFiniteIp, postHasLong);
    fprintf(fid, 'status: %s\n', tr.status);
    fprintf(fid, 'verdict: %s\n', verdict);
    fprintf(fid, 'okLen=%d okFill=%d okPost=%d okLong=%d\n', okLen, okFill, okPost, okLong);
    fprintf(fid, 'outDir: %s\n', outDir);
    fclose(fid);

    fprintf('Saved: %s\n', outDir);
    if ~strcmp(verdict, 'PASS')
        error('run_trk100s_smoke:Fail', 'Chunk-coverage checks failed (see %s)', outDir);
    end
end
