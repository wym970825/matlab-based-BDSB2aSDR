function [corr, remCodePhase, remCarrPhase] = correlateB2aMs( ...
    rawSignal, codeData, codePilot, remCodePhase, remCarrPhase, ...
    codeFreq, carrFreq, fs, codeLength, elSpc, nh)
%CORRELATEB2AMS One-millisecond B2a dual-channel E/P/L correlator (P2).
%
% Uses MEX (correlateB2aMs_mex) when on path; else pure MATLAB.
%
% Outputs
%   corr          - struct of I/Q early/prompt/late for data & pilot
%   remCodePhase  - updated residual code phase
%   remCarrPhase  - updated residual carrier phase

    persistent useMex
    if isempty(useMex)
        useMex = (exist('correlateB2aMs_mex', 'file') == 3);
    end
    if useMex
        raw = rawSignal(:).';
        if ~iscolumn(codeData), codeData = codeData(:).'; end
        if ~iscolumn(codePilot), codePilot = codePilot(:).'; end
        [v, remCodePhase, remCarrPhase] = correlateB2aMs_mex( ...
            complex(raw), double(codeData), double(codePilot), ...
            double(remCodePhase), double(remCarrPhase), ...
            double(codeFreq), double(carrFreq), double(fs), ...
            double(codeLength), double(elSpc), double(nh));
        corr = struct( ...
            'I_E', v(1), 'Q_E', v(2), 'I_P', v(3), 'Q_P', v(4), ...
            'I_L', v(5), 'Q_L', v(6), ...
            'Pilot_I_E', v(7), 'Pilot_Q_E', v(8), ...
            'Pilot_I_P', v(9), 'Pilot_Q_P', v(10), ...
            'Pilot_I_L', v(11), 'Pilot_Q_L', v(12));
        return;
    end

    codePhaseStep = codeFreq / fs;
    blksize = ceil((codeLength - remCodePhase) / codePhaseStep);
    if blksize < 1
        blksize = 1;
    end
    nSig = numel(rawSignal);
    if blksize > nSig
        blksize = nSig;
    end

    % Early / late / prompt code indices (MATLAB 1-based into padded code)
    tE = (remCodePhase - elSpc) : codePhaseStep : ((blksize-1)*codePhaseStep + remCodePhase - elSpc);
    tL = (remCodePhase + elSpc) : codePhaseStep : ((blksize-1)*codePhaseStep + remCodePhase + elSpc);
    tP = remCodePhase : codePhaseStep : ((blksize-1)*codePhaseStep + remCodePhase);

    % Length may be blksize or blksize+1 depending on floating remainder — clamp
    nE = min(numel(tE), blksize);
    nL = min(numel(tL), blksize);
    nP = min(numel(tP), blksize);
    n = min([nE, nL, nP, blksize]);

    idxE = ceil(tE(1:n)) + 1;
    idxL = ceil(tL(1:n)) + 1;
    idxP = ceil(tP(1:n)) + 1;

    earlyCode  = codeData(idxE);
    lateCode   = codeData(idxL);
    promptCode = codeData(idxP);
    earlyCodeQ  = nh * codePilot(idxE);
    lateCodeQ   = nh * codePilot(idxL);
    promptCodeQ = nh * codePilot(idxP);

    % Carrier wipe-off
    timetick = (0:n) ./ fs;
    trigarg = ((carrFreq * 2*pi) .* timetick) + remCarrPhase;
    remCarrPhase = rem(trigarg(n+1), 2*pi);
    carrsig = exp(1i * trigarg(1:n));

    baseBand = rawSignal(1:n) .* carrsig;
    qbb = real(baseBand);
    ibb = imag(baseBand);

    corr = struct();
    corr.I_E = sum(earlyCode  .* ibb);
    corr.Q_E = sum(earlyCode  .* qbb);
    corr.I_P = sum(promptCode .* ibb);
    corr.Q_P = sum(promptCode .* qbb);
    corr.I_L = sum(lateCode   .* ibb);
    corr.Q_L = sum(lateCode   .* qbb);
    corr.Pilot_I_E = sum(earlyCodeQ  .* ibb);
    corr.Pilot_Q_E = sum(earlyCodeQ  .* qbb);
    corr.Pilot_I_P = sum(promptCodeQ .* ibb);
    corr.Pilot_Q_P = sum(promptCodeQ .* qbb);
    corr.Pilot_I_L = sum(lateCodeQ   .* ibb);
    corr.Pilot_Q_L = sum(lateCodeQ   .* qbb);

    remCodePhase = tP(n) + codePhaseStep - codeLength;
end
