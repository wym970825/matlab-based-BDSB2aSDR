function cs = nmeaChecksum(body)
%NMEACHECKSUM XOR checksum for NMEA body (between '$' and '*', no '$'/'*').
%
%   cs = nmeaChecksum(body)  → two-char uppercase hex string, e.g. '4F'

    if isempty(body)
        cs = '00';
        return;
    end
    body = char(body);
    if body(1) == '$'
        body = body(2:end);
    end
    star = find(body == '*', 1, 'first');
    if ~isempty(star)
        body = body(1:star-1);
    end
    x = uint8(0);
    b = uint8(body);
    for i = 1:numel(b)
        x = bitxor(x, b(i));
    end
    cs = upper(dec2hex(double(x), 2));
end
