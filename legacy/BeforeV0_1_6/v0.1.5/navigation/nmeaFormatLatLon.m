function [latField, ns, lonField, ew] = nmeaFormatLatLon(latDeg, lonDeg)
%NMEAFORMATLATLON Convert decimal degrees to NMEA ddmm.mmmm / dddmm.mmmm.

    if ~isfinite(latDeg) || ~isfinite(lonDeg)
        latField = '';
        ns = '';
        lonField = '';
        ew = '';
        return;
    end

    if latDeg >= 0
        ns = 'N';
    else
        ns = 'S';
        latDeg = -latDeg;
    end
    latD = floor(latDeg);
    latM = (latDeg - latD) * 60;
    latField = sprintf('%02d%07.4f', latD, latM);

    if lonDeg >= 0
        ew = 'E';
    else
        ew = 'W';
        lonDeg = -lonDeg;
    end
    lonD = floor(lonDeg);
    lonM = (lonDeg - lonD) * 60;
    lonField = sprintf('%03d%07.4f', lonD, lonM);
end
