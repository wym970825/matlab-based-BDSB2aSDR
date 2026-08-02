function codeFreq = codeFreqFromCarrierAid(settings, carrFreq, codeNco)
%CODEFREQFROMCARRIERAID Nominal code rate + optional limited carrier aid − DLL.
%
%   codeFreq = codeFreqFromCarrierAid(settings, carrFreq, codeNco)
%
%   When settings.carrierAidCode is true (default):
%     residual = carrFreq + IF   % wipe-off uses carrFreq≈-(IF+fd); Zero-IF: IF=0
%     aid = -residual * (codeFreqBasis / carrFreqBasis)
%     aid = clamp(aid, ±carrierAidCodeMaxHz)
%     codeFreq = codeFreqBasis + aid - codeNco
%   Else (legacy SoftGNSS):
%     codeFreq = codeFreqBasis - codeNco
%
%   Important: wipe-off carrFreq is IF-domain (e.g. ≈-1.05e6 for IF=1.05e6).
%   Code Doppler must use residual only (≈-fd). Using raw carrFreq saturates
%   ±maxAid (~±50 Hz) and prevents LONG lock on non-zero-IF files.

    if nargin < 3 || isempty(codeNco), codeNco = 0; end
    f0 = settings.codeFreqBasis;
    useAid = isfield(settings, 'carrierAidCode') && logical(settings.carrierAidCode);
    if ~useAid
        codeFreq = f0 - codeNco;
        return;
    end
    fL = settings.carrFreqBasis;
    if ~(isfinite(fL) && fL > 0)
        fL = 1176.45e6;
    end
    if0 = 0;
    if isfield(settings, 'IF') && isfinite(settings.IF)
        if0 = settings.IF;
    end
    % Acq stores carrFreq ≈ -fineFreq; fineFreq ≈ IF + fd → residual ≈ carrFreq + IF
    residual = carrFreq + if0;
    aid = -residual * (f0 / fL);
    maxAid = 50;
    if isfield(settings, 'carrierAidCodeMaxHz') && ~isempty(settings.carrierAidCodeMaxHz) ...
            && isfinite(settings.carrierAidCodeMaxHz)
        maxAid = abs(settings.carrierAidCodeMaxHz);
    end
    if aid > maxAid
        aid = maxAid;
    elseif aid < -maxAid
        aid = -maxAid;
    end
    codeFreq = f0 + aid - codeNco;
end
