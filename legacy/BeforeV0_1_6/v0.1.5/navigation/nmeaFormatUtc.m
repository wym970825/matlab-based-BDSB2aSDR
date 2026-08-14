function hhmmss = nmeaFormatUtc(sowSec, bdtMinusUtc)
%NMEAFORMATUTC Format constellation time [s] as hhmmss.ss for NMEA GGA.
%
%   hhmmss = nmeaFormatUtc(sowSec, bdtMinusUtc)
%
% SoftGNSS localTime is typically BDT-scale continuous time / SOW.
% GGA needs UTC *time of day*:
%   sod = mod(sow − bdtMinusUtc, 86400)
% Default bdtMinusUtc = 4 (BDT ≈ UTC + 4 s).

    if nargin < 2 || isempty(bdtMinusUtc) || ~isfinite(bdtMinusUtc)
        bdtMinusUtc = 4;
    end
    if ~isfinite(sowSec)
        hhmmss = '';
        return;
    end
    % Week wrap then day wrap → hh:mm:ss
    sow = mod(sowSec - bdtMinusUtc, 604800);
    if sow < 0
        sow = sow + 604800;
    end
    sod = mod(sow, 86400);
    if sod < 0
        sod = sod + 86400;
    end
    h = floor(sod / 3600);
    m = floor(mod(sod, 3600) / 60);
    s = mod(sod, 60);
    hhmmss = sprintf('%02d%02d%05.2f', h, m, s);
end
