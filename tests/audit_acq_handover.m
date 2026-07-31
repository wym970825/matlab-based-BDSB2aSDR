function audit_acq_handover()
%AUDIT_ACQ_HANDOVER Re-check first acquisition + acq→track handover.
% 1) Full PRN peak table already on disk; recompute power at acq geometry
%    vs at tracking seek position for the 8 acquired PRNs.
% 2) Optional: longer-integration coarse scan for near-miss PRNs.

    setupPaths();
    S = load(fullfile('results','smoke','fullsky_lock_260730_162438','fullsky_lock.mat'));
    R = S.report;
    ar = R.acqResults;
    settings = R.settings;

    % Rebuild acq-time settings (1:60 search)
    settings.acqSatelliteList = 1:60;
    settings.msToProcess = max(settings.msToProcess, 10);

    [fid, dataAdaptCoeff] = openIfFile(settings);
    cleaner = onCleanup(@() local_fclose(fid)); %#ok<NASGU>

    samplesNeededMs = settings.fineNoncoh + 2;
    data = readIfBlock(fid, settings, dataAdaptCoeff, samplesNeededMs);
    if settings.EnablePB
        pb = pulseBlanker(settings);
        data = pb.f_mitigate(data, settings.usrp.scaleK, settings.usrp.gain, settings.samplingFreq);
    end

    fs = settings.samplingFreq;
    codeFreq = settings.codeFreqBasis;
    codeLen = settings.codeLength;
    samplesPerCode = round(fs / (codeFreq / codeLen));
    fineNcoh = settings.fineNoncoh;
    Nbuf = numel(data);

    fprintf('=== Acq buffer audit ===\n');
    fprintf('buffer length = %d samples (%.3f ms)\n', Nbuf, 1e3*Nbuf/fs);
    fprintf('samplesPerCode = %d  fineNoncoh = %d\n', samplesPerCode, fineNcoh);
    fprintf('coarse uses TAIL 1ms of buffer (SoftGNSS-style)\n');
    fprintf('track seek uses skipNumberOfBytes + (codePhase-1)*bytes  [NO + (Nbuf-samplesPerCode)]\n\n');

    % Acquired indices in ar (length 60, list 1:60)
    list = 1:60;
    acqMask = isfinite(ar.carrFreq(:)) & (ar.carrFreq(:) ~= 0);

    fprintf('%-5s %8s %8s %10s %10s %10s %10s %10s %8s\n', ...
        'PRN', 'peak', 'CN0pAcq', 'P_tail', 'P_head', 'P_seek0', 'ratioT/H', 'ratioT/S', 'LONG%');
    rows = [];
    for k = find(acqMask).'
        prn = list(k);
        codePhase = ar.codePhase(k);
        carr = ar.carrFreq(k);      % stored for tracking
        % fine stage used f = -carr for wipe (since stored = -bestFineFreq)
        fineF = -carr;
        weil = ar.weilPhase(k);
        pol = ar.polarityRef(k);

        % --- power at acq tail geometry (same as fine stage window end) ---
        edAbs = Nbuf - samplesPerCode + (codePhase - 1);
        stAbs = edAbs - fineNcoh*samplesPerCode + 1;
        if stAbs < 1 || edAbs > Nbuf
            warning('PRN%d fine window OOB st=%d ed=%d', prn, stAbs, edAbs);
            continue;
        end
        sigFine = data(stAbs:edAbs);
        P_tail = pilotPowerMs(sigFine, prn, settings, fineF, weil, pol, samplesPerCode);

        % --- power if we wrongly take HEAD of buffer with same codePhase ---
        stHead = codePhase;
        edHead = stHead + fineNcoh*samplesPerCode - 1;
        if edHead <= Nbuf
            sigHead = data(stHead:edHead);
            P_head = pilotPowerMs(sigHead, prn, settings, fineF, weil, pol, samplesPerCode);
        else
            P_head = NaN;
        end

        % --- power at TRACKING seek position: first fineNcoh ms after seek ---
        % trackOneChannel seeks to skipBytes + (codePhase-1)*size, then reads
        % from there. File was rewound conceptually: same as buffer index codePhase
        % if skip=0 and acq started at same place.
        stSeek = codePhase;
        edSeek = stSeek + fineNcoh*samplesPerCode - 1;
        if edSeek <= Nbuf
            sigSeek = data(stSeek:edSeek);
            % tracking starts remCodePhase=0, uses carr=acquiredFreq=carr, polarity
            P_seek = pilotPowerMs(sigSeek, prn, settings, fineF, weil, pol, samplesPerCode);
            % also without Weil wipe (INIT-like)
            P_seek_noW = pilotPowerMs(sigSeek, prn, settings, fineF, 0, pol, samplesPerCode, false);
        else
            P_seek = NaN; P_seek_noW = NaN;
        end

        % track long%
        longPct = NaN; meanCNo = NaN;
        for c = 1:numel(R.trackResults)
            if R.trackResults(c).PRN == prn
                tr = R.trackResults(c);
                N = min(numel(tr.cur_state), settings.msToProcess);
                longPct = 100*mean(tr.cur_state(1:N));
                cno = tr.B2a_CNo; cno = cno(isfinite(cno));
                if ~isempty(cno), meanCNo = mean(cno); end
                break;
            end
        end

        rTH = P_tail / max(P_head, eps);
        rTS = P_tail / max(P_seek, eps);
        fprintf('%-5d %8.3f %8.1f %10.3g %10.3g %10.3g %10.2f %10.2f %8.1f\n', ...
            prn, ar.peakMetric(k), ar.CN0_pilot(k), P_tail, P_head, P_seek, rTH, rTS, longPct);

        rows = [rows; struct('PRN',prn,'P_tail',P_tail,'P_head',P_head,'P_seek',P_seek, ...
            'P_seek_noW',P_seek_noW,'longPct',longPct,'meanCNo',meanCNo, ...
            'peak',ar.peakMetric(k),'CN0p',ar.CN0_pilot(k),'codePhase',codePhase, ...
            'carr',carr,'weil',weil,'pol',pol)]; %#ok<AGROW>
    end

    fprintf('\n=== Interpretation guide ===\n');
    fprintf('If P_tail >> P_seek: signal at acq tail, weak at track seek → HANDOVER offset bug.\n');
    fprintf('If P_tail ≈ P_seek both strong but track failed: loop/state-machine bug.\n');
    fprintf('If P_tail weak: fine CN0_pilot inflated / false acq.\n');

    % --- Re-acquire with more noncoherent (sensitivity check) ---
    fprintf('\n=== Re-acq sensitivity: fineNoncoh=20, same 1:60 (coarse still 1ms tail) ===\n');
    settings2 = settings;
    settings2.fineNoncoh = 20;
    % need more data
    local_fclose(fid);
    [fid, dataAdaptCoeff] = openIfFile(settings2);
    cleaner = onCleanup(@() local_fclose(fid));
    data2 = readIfBlock(fid, settings2, dataAdaptCoeff, settings2.fineNoncoh + 2);
    if settings2.EnablePB
        pb = pulseBlanker(settings2);
        data2 = pb.f_mitigate(data2, settings2.usrp.scaleK, settings2.usrp.gain, settings2.samplingFreq);
    end
    t0 = tic;
    ar2 = acquisition_robust_v2fft(data2, settings2, 'STA', 'INIT', 'USEFFT', false, 'ISSILENT', true);
    fprintf('re-acq wall %.1f s\n', toc(t0));
    list2 = settings2.acqSatelliteList(:)';
    cf2 = ar2.carrFreq(:); pm2 = ar2.peakMetric(:);
    acq2 = isfinite(cf2) & (cf2 ~= 0);
    fprintf('Acquired with fineNoncoh=20: %d PRNs\n', nnz(acq2));
    [~,ord] = sort(pm2, 'descend');
    fprintf('Top 15:\n');
    for i = 1:min(15, numel(list2))
        k = ord(i);
        fprintf('  PRN%02d peak=%.3f carr=%.1f acq=%d CN0p=%.1f\n', ...
            list2(k), pm2(k), cf2(k), acq2(k), ar2.CN0_pilot(k));
    end

    outDir = fullfile('results','smoke','fullsky_lock_260730_162438');
    save(fullfile(outDir, 'acq_handover_audit.mat'), 'rows', 'ar', 'ar2', 'settings', 'settings2');
    writeReport(fullfile(outDir, 'acq_reaudit.md'), rows, ar, ar2, list2, settings, settings2);
    fprintf('\nWrote %s\n', fullfile(outDir, 'acq_reaudit.md'));
end

function P = pilotPowerMs(sig, prn, settings, fineF, weilPhase, pol, samplesPerCode, useWeil)
    if nargin < 8, useWeil = true; end
    fs = settings.samplingFreq;
    ts = 1/fs;
    nMs = floor(numel(sig) / samplesPerCode);
    if nMs < 1, P = NaN; return; end
    sig = sig(1:nMs*samplesPerCode);
    pilotChips = generateB2aPilotCode(prn, settings);
    codeLen = settings.codeLength;
    codeFreq = settings.codeFreqBasis;
    codeIdx = floor((ts*(1:samplesPerCode)) / (1/codeFreq));
    localPilot = pilotChips(rem(codeIdx, codeLen) + 1);
    localPilot = localPilot(:).';
    weil100 = GenWeil(prn);
    t = (0:numel(sig)-1) * ts;
    bb = sig(:).' .* exp(-1i * fineF * 2*pi .* t);  % note: 2*pi? check acq
    % acquisition uses exp(-1i * f * phasePoints) with phasePoints = (0:N-1)*2*pi*ts
    % so omega = f * 2*pi  when f in Hz... phasePoints = (0:)*2*pi*ts, * f => 2*pi*f*t YES

    % Wait: acq has phasePoints1ms = (0:samplesPerCode-1)*2*pi*ts; carr = exp(-1i*f*phasePoints)
    % so argument = f * 2*pi * t. Good.

    acc = 0;
    for l = 1:nMs
        idx = (l-1)*samplesPerCode + (1:samplesPerCode);
        w = 1;
        if useWeil
            w = weil100(mod(weilPhase + (l-1), 100) + 1);
        end
        if pol < 0, w = -w; end
        acc = acc + abs(sum(bb(idx) .* localPilot * w))^2;
    end
    P = acc / nMs;
end

function writeReport(path, rows, ar, ar2, list2, settings, settings2)
    fid = fopen(path, 'w');
    fprintf(fid, '# Acquisition re-audit (first capture)\n\n');
    fprintf(fid, 'User concern: clear-sky should not only track 4 SVs.\n\n');
    fprintf(fid, '## 1. What the first capture actually found\n\n');
    fprintf(fid, '- Search list: PRN 1:60, `acqThreshold=%.2f`, band=±%.0f Hz, step=%.0f Hz, fineNoncoh=%d\n', ...
        settings.acqThreshold, settings.acqSearchBand, settings.acqStep, settings.fineNoncoh);
    fprintf(fid, '- Coarse uses **only the last 1 ms** of a %d ms buffer\n', settings.fineNoncoh+2);
    fprintf(fid, '- Declared acquired: **8** PRNs (not 4). Track stabilized **4**.\n\n');
    fprintf(fid, '## 2. Peak ranking (first acq)\n\n');
    fprintf(fid, 'No PRN sits in a grey zone just below threshold: #8=PRN23 peak=2.85, #9=PRN15 peak=1.79 (noise).\n');
    fprintf(fid, 'Raising sensitivity via threshold alone will not magically add true SVs without more integration.\n\n');
    fprintf(fid, '## 3. Handover power check (this run)\n\n');
    fprintf(fid, '| PRN | peak | CN0p acq | P_tail | P_head | P_seek | P_tail/P_seek | LONG%% |\n');
    fprintf(fid, '|----:|-----:|---------:|-------:|-------:|-------:|--------------:|------:|\n');
    for i = 1:numel(rows)
        r = rows(i);
        fprintf(fid, '| %d | %.3f | %.1f | %.3g | %.3g | %.3g | %.2f | %.1f |\n', ...
            r.PRN, r.peak, r.CN0p, r.P_tail, r.P_head, r.P_seek, r.P_tail/max(r.P_seek,eps), r.longPct);
    end
    fprintf(fid, '\n## 4. Re-acq with fineNoncoh=%d\n\n', settings2.fineNoncoh);
    cf2 = ar2.carrFreq(:); pm2 = ar2.peakMetric(:);
    acq2 = isfinite(cf2) & (cf2 ~= 0);
    fprintf(fid, 'Acquired count: **%d**\n\n', nnz(acq2));
    [~,ord] = sort(pm2, 'descend');
    fprintf(fid, '| PRN | peak | carr | acq | CN0p |\n|----:|-----:|-----:|:---:|-----:|\n');
    for i = 1:min(20, numel(list2))
        k = ord(i);
        fprintf(fid, '| %d | %.3f | %.1f | %d | %.1f |\n', ...
            list2(k), pm2(k), cf2(k), acq2(k), ar2.CN0_pilot(k));
    end
    fprintf(fid, '\n## 5. Conclusions\n\n');
    fprintf(fid, '(filled by runner notes in console; see mat for numbers)\n');
    fclose(fid);
end

function local_fclose(fid)
    if ~isempty(fid) && fid > 0
        try, fclose(fid); catch, end %#ok<CTCH>
    end
end
