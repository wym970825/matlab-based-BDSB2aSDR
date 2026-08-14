function sentences = nmeaBuildGSV(talker, prn, elevDeg, azDeg, snrDb)
%NMEABUILDGSV Build one or more NMEA GSV sentences (≤4 SV per message).
%
%   sentences = nmeaBuildGSV(talker, prn, elevDeg, azDeg, snrDb)
%
% prn/elev/az/snr: equal-length vectors; non-finite elev drops SV.
% snr may be NaN → empty SNR field.
% Returns cellstr of full sentences including CR LF.

    sentences = {};
    if nargin < 1 || isempty(talker), talker = 'GB'; end
    talker = upper(char(talker));
    if numel(talker) ~= 2, talker = 'GB'; end

    prn = prn(:);
    elevDeg = elevDeg(:);
    azDeg = azDeg(:);
    if nargin < 5 || isempty(snrDb)
        snrDb = nan(size(prn));
    else
        snrDb = snrDb(:);
    end
    nIn = max([numel(prn), numel(elevDeg), numel(azDeg), numel(snrDb)]);
    if nIn < 1
        return;
    end
    if numel(prn) < nIn, prn(end+1:nIn) = NaN; end
    if numel(elevDeg) < nIn, elevDeg(end+1:nIn) = NaN; end
    if numel(azDeg) < nIn, azDeg(end+1:nIn) = NaN; end
    if numel(snrDb) < nIn, snrDb(end+1:nIn) = NaN; end

    keep = isfinite(prn) & prn > 0 & isfinite(elevDeg);
    prn = prn(keep);
    elevDeg = elevDeg(keep);
    azDeg = azDeg(keep);
    snrDb = snrDb(keep);
    nSat = numel(prn);
    if nSat < 1
        return;
    end

    nMsg = ceil(nSat / 4);
    sentences = cell(nMsg, 1);
    for m = 1:nMsg
        i0 = (m-1)*4 + 1;
        i1 = min(m*4, nSat);
        chunks = cell(1, i1-i0+1);
        for k = i0:i1
            j = k - i0 + 1;
            el = max(0, min(90, round(elevDeg(k))));
            az = azDeg(k);
            if ~isfinite(az)
                azStr = '';
            else
                az = mod(round(az), 360);
                if az < 0, az = az + 360; end
                azStr = sprintf('%03d', az);
            end
            if isfinite(snrDb(k)) && snrDb(k) > 0
                snrStr = sprintf('%02d', max(0, min(99, round(snrDb(k)))));
            else
                snrStr = '';
            end
            chunks{j} = sprintf('%02d,%d,%s,%s', ...
                max(1, min(99, round(prn(k)))), el, azStr, snrStr);
        end
        body = sprintf('%sGSV,%d,%d,%02d,%s', ...
            talker, nMsg, m, nSat, strjoin(chunks, ','));
        sentences{m} = sprintf('$%s*%s\r\n', body, nmeaChecksum(body));
    end
end
