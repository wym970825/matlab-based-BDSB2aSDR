function hhmmss = nmeaFormatUtc(sowSec, utcOffsetSeconds)
%NMEAFORMATUTC Format constellation time [s] as hhmmss.ss UTC.
%
%   hhmmss = nmeaFormatUtc(sowSec, utcOffsetSeconds)
%
% UTC = receiver time minus UTCOFFSETSECONDS. The caller supplies the time
% system offset, so this formatter is not tied to a particular constellation.

    if nargin < 2 || isempty(utcOffsetSeconds) || ~isfinite(utcOffsetSeconds)
        utcOffsetSeconds = 0;
    end
    if ~isfinite(sowSec)
        hhmmss = '';
        return;
    end
    % Week wrap then day wrap → hh:mm:ss
    sow = mod(sowSec - utcOffsetSeconds, 604800);
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
