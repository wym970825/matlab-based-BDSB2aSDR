function tests = test_nav_track_time_order
%TEST_NAV_TRACK_TIME_ORDER Verify continuous local ENU across UTM zones.
    tests = functiontests(localfunctions);
end

function testCrossUtmBoundaryUsesEcefEnu(testCase)
    lat = [27, 27, 27];
    lon = [107.9999, 108.0000, 108.0001];
    h = [1000, 1000, 1000];
    [x, y, z] = localLlaToEcef(lat, lon, h);
    nav = struct();
    nav.latitude = lat;
    nav.longitude = lon;
    nav.height = h;
    nav.X = x;
    nav.Y = y;
    nav.Z = z;
    % Deliberately emulate two incompatible UTM easting zones.
    nav.E = [800000, 200000, 200010];
    nav.N = [3e6, 3e6, 3e6];
    nav.U = h;
    nav.DOP = nan(5, 3);

    trk = navTrackTimeOrder(nav, struct( ...
        'navSolPeriod', 500, 'navTrackMaxSpeedMps', 500));

    verifyEqual(testCase, trk.n, 3);
    verifyEqual(testCase, trk.nRemovedJump, 0);
    verifyLessThan(testCase, max(abs(diff(trk.E))), 20);
end

function [x, y, z] = localLlaToEcef(latDeg, lonDeg, h)
    a = 6378137;
    e2 = 6.69437999014e-3;
    lat = latDeg * pi / 180;
    lon = lonDeg * pi / 180;
    n = a ./ sqrt(1 - e2 * sin(lat).^2);
    x = (n + h) .* cos(lat) .* cos(lon);
    y = (n + h) .* cos(lat) .* sin(lon);
    z = (n .* (1 - e2) + h) .* sin(lat);
end
