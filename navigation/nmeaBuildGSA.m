function sentence = nmeaBuildGSA(talker, selectionMode, fixType, ...
        satelliteIds, pdop, hdop, vdop, systemId)
%NMEABUILDGSA Build one constellation-neutral NMEA GSA sentence.
%
%   sentence = nmeaBuildGSA(talker, mode, fixType, satelliteIds, ...
%       pdop, hdop, vdop)
%   sentence = nmeaBuildGSA(..., systemId)
%
% SATELLITEIDS contains the satellites used by the position solution, not
% every satellite in view. Up to 12 identifiers are written. SYSTEMID is
% the optional NMEA 4.x GNSS system identifier; omit it for older receivers.

    if nargin < 1 || isempty(talker), talker = 'GN'; end
    talker = upper(char(talker));
    if numel(talker) ~= 2 || any(~isstrprop(talker, 'alphanum'))
        talker = 'GN';
    end

    if nargin < 2 || isempty(selectionMode), selectionMode = 'A'; end
    selectionMode = upper(char(selectionMode));
    if numel(selectionMode) ~= 1 || ~ismember(selectionMode, ['A', 'M'])
        selectionMode = 'A';
    end
    if nargin < 3 || isempty(fixType) || ~isfinite(fixType)
        fixType = 1;
    end
    fixType = max(1, min(3, round(fixType)));
    if nargin < 4 || isempty(satelliteIds)
        satelliteIds = [];
    end

    ids = satelliteIds(:).';
    ids = ids(isfinite(ids) & ids > 0);
    ids = round(ids(1:min(12, numel(ids))));
    svFields = repmat({''}, 1, 12);
    for idx = 1:numel(ids)
        svFields{idx} = localSatelliteId(ids(idx));
    end

    if nargin < 5 || isempty(pdop) || ~isfinite(pdop), pdopText = ''; else, pdopText = sprintf('%.1f', pdop); end
    if nargin < 6 || isempty(hdop) || ~isfinite(hdop), hdopText = ''; else, hdopText = sprintf('%.1f', hdop); end
    if nargin < 7 || isempty(vdop) || ~isfinite(vdop), vdopText = ''; else, vdopText = sprintf('%.1f', vdop); end

    body = sprintf('%sGSA,%s,%d,%s,%s,%s,%s', talker, selectionMode, ...
        fixType, strjoin(svFields, ','), pdopText, hdopText, vdopText);
    if nargin >= 8 && ~isempty(systemId) && isfinite(systemId)
        body = sprintf('%s,%d', body, max(0, round(systemId)));
    end
    sentence = sprintf('$%s*%s\r\n', body, nmeaChecksum(body));
end

function text = localSatelliteId(value)
    value = max(1, round(value));
    if value < 100
        text = sprintf('%02d', value);
    else
        text = sprintf('%d', value);
    end
end
