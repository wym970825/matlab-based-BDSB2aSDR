function sentence = nmeaBuildGGA(talker, utc, latDeg, lonDeg, quality, nSat, hdop, altM, geoidSepM)
%NMEABUILDGGA Build one NMEA GGA sentence (with $ *cs CR LF).
%
%   $ttGGA,hhmmss.ss,ddmm.mmmm,N,dddmm.mmmm,E,q,nn,hdop,alt,M,geoid,M,,*cs

    if nargin < 1 || isempty(talker), talker = 'GB'; end
    talker = upper(char(talker));
    if numel(talker) ~= 2, talker = 'GB'; end

    if nargin < 5 || isempty(quality), quality = 0; end
    if nargin < 6 || isempty(nSat) || ~isfinite(nSat), nSat = 0; end
    if nargin < 7 || ~isfinite(hdop), hdopStr = ''; else, hdopStr = sprintf('%.1f', hdop); end
    if nargin < 8 || ~isfinite(altM), altStr = ''; else, altStr = sprintf('%.1f', altM); end
    if nargin < 9 || ~isfinite(geoidSepM), geoStr = ''; else, geoStr = sprintf('%.1f', geoidSepM); end

    [latF, ns, lonF, ew] = nmeaFormatLatLon(latDeg, lonDeg);
    if isempty(latF) || isempty(utc)
        quality = 0;
    end

    body = sprintf('%sGGA,%s,%s,%s,%s,%s,%d,%02d,%s,%s,M,%s,M,,', ...
        talker, utc, latF, ns, lonF, ew, ...
        max(0, round(quality)), max(0, min(99, round(nSat))), ...
        hdopStr, altStr, geoStr);
    sentence = sprintf('$%s*%s\r\n', body, nmeaChecksum(body));
end
