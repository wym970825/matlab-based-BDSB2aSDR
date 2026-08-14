function [pf, Wn] = calcLoopCoef_NHSM(order, IntT_ms, BW_Hz, zeta)
%calcLoopCoef_NHSM  Loop coefficients helper (NHSM)
%
% [pf, Wn] = calcLoopCoef_NHSM(order, IntT_ms, BW_Hz, zeta)
%
% Backward compatible:
%   pf = calcLoopCoef_NHSM(order, IntT_ms, BW_Hz)   % assumes zeta = 0.707
%
% Notes:
% - BW_Hz is bandwidth in Hz (your conventional loop BW config style).
% - zeta is damping factor (default 0.707).
% - Wn is the natural frequency (rad/s) of an equivalent 2nd-order model.
%
% This keeps legacy behavior if zeta is omitted.

if nargin < 4 || isempty(zeta)
    zeta = 0.707;
end

IntT = IntT_ms/1e3;
Wn = NaN;

if order == 2
    % Standard 2nd-order relationship (Hz BW -> rad/s Wn):
    % BW_Hz = (Wn/(2*pi)) * ( (4*zeta^2 + 1) / (4*zeta) )
    % => Wn = 2*pi*BW_Hz * (4*zeta)/(4*zeta^2 + 1)
    Wn = 2*pi*BW_Hz * (4*zeta) / (4*zeta^2 + 1);

    a2 = 2*zeta;
    pf2 = Wn^2 * IntT;
    pf1 = a2 * Wn;
    pf = [pf1; pf2];

elseif order == 3
    % Keep your original 3rd order empirical constants (legacy)
    a3 = 1.1;
    b3 = 2.4;
    Wn = 2*pi * (BW_Hz / 0.7845);  % legacy mapping
    pf3 = Wn^3 * IntT^2;
    pf2 = a3 * Wn^2 * IntT;
    pf1 = b3 * Wn;
    pf  = [pf1; pf2; pf3];

else
    error('calcLoopCoef_NHSM:InvalidOrder','order must be 2 or 3');
end
end
