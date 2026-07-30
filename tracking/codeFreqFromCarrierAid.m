function codeFreq = codeFreqFromCarrierAid(settings, carrFreq, codeNco)
%CODEFREQFROMCARRIERAID Nominal code rate + optional limited carrier aid − DLL.
%
%   codeFreq = codeFreqFromCarrierAid(settings, carrFreq, codeNco)
%
%   When settings.carrierAidCode is true (default):
%     aid = -carrFreq * (codeFreqBasis / carrFreqBasis)  % instantaneous NCO
%     aid = clamp(aid, ±carrierAidCodeMaxHz)             % code-domain Hz
%     codeFreq = codeFreqBasis + aid - codeNco
%   Else (legacy SoftGNSS):
%     codeFreq = codeFreqBasis - codeNco
%
%   Sign note: this receiver stores wipe-off carrFreq with acq convention
%   (carrFreq = -fineFreq). Empirically locked tracks show
%   (codeFreq-f0) ≈ -carrFreq*(f0/fL); use that polarity for aiding.

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
    aid = -carrFreq * (f0 / fL);  % match observed code/carrier polarity
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
