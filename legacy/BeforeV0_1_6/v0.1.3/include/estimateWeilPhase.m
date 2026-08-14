function [bestPhase, bestZ, conf, secondZ] = estimateWeilPhase(PpBuf, weil100)
%estimateWeilPhase  Estimate Weil(100) start phase by enumeration.
%
% Inputs:
%   PpBuf   - 1xL complex pilot prompt values (already rotated -pi/2),
%            MUST be "raw" (NOT NH wiped)
%   weil100 - 1x100 +/-1 Weil sequence for this PRN
%
% Outputs:
%   bestPhase - integer in [0..99]
%   bestZ     - abs(sum(w .* PpBuf)) at best phase
%   conf      - bestZ / secondZ (confidence proxy)
%   secondZ   - 2nd best metric

PpBuf = PpBuf(:).';          % row
L = numel(PpBuf);
assert(numel(weil100) == 100, 'weil100 must be length 100.');
weil100 = weil100(:).';

Zs = zeros(1,100);

idx = 0:(L-1);
for s = 0:99
    w = weil100(mod(s + idx, 100) + 1);
    Zs(s+1) = abs(sum(w .* PpBuf));
end

[bestZ, k] = max(Zs);
bestPhase = k - 1;

Zs(k) = -inf;
secondZ = max(Zs);

if secondZ <= 0
    conf = inf;
else
    conf = bestZ / secondZ;
end
end
