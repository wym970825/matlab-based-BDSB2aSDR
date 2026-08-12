function sentence = nmeaBuildZDA(talker, utc, dayNumber, monthNumber, ...
        yearNumber, localZoneHours, localZoneMinutes)
%NMEABUILDZDA Build one constellation-neutral NMEA ZDA sentence.
%
%   $ttZDA,hhmmss.ss,dd,mm,yyyy,xx,yy*cs
%
% UTC is a preformatted NMEA time field. Date and local-zone values are
% supplied by the caller so this builder has no constellation time-system
% assumptions.

    if nargin < 1 || isempty(talker), talker = 'GN'; end
    talker = upper(char(talker));
    if numel(talker) ~= 2 || any(~isstrprop(talker, 'alphanum'))
        talker = 'GN';
    end
    if nargin < 2 || isempty(utc)
        utc = '';
    else
        utc = char(utc);
    end
    if nargin < 3 || isempty(dayNumber) || ~isfinite(dayNumber), dayNumber = 0; end
    if nargin < 4 || isempty(monthNumber) || ~isfinite(monthNumber), monthNumber = 0; end
    if nargin < 5 || isempty(yearNumber) || ~isfinite(yearNumber), yearNumber = 0; end
    if nargin < 6 || isempty(localZoneHours) || ~isfinite(localZoneHours), localZoneHours = 0; end
    if nargin < 7 || isempty(localZoneMinutes) || ~isfinite(localZoneMinutes), localZoneMinutes = 0; end

    zoneHoursText = localZoneHoursText(localZoneHours);
    body = sprintf('%sZDA,%s,%02d,%02d,%04d,%s,%02d', talker, utc, ...
        max(0, round(dayNumber)), max(0, round(monthNumber)), ...
        max(0, round(yearNumber)), zoneHoursText, ...
        max(0, min(59, abs(round(localZoneMinutes)))));
    sentence = sprintf('$%s*%s\r\n', body, nmeaChecksum(body));
end

function text = localZoneHoursText(value)
    value = max(-13, min(13, round(value)));
    if value < 0
        text = sprintf('-%02d', abs(value));
    else
        text = sprintf('%02d', value);
    end
end
