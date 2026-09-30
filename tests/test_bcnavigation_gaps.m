function tests = test_bcnavigation_gaps
% Decode real CRC-24Q frames on each side of missing/reacquired samples.
    tests = functiontests(localfunctions);
end

function testKnownFrame(testCase)
    [eph, sf, tow] = BCNAV2decoding(localFrame(300));
    verifyEqual(testCase, eph.PRN, 11);
    verifyEqual(testCase, sf, 1);
    verifyEqual(testCase, tow, 300);
end

function testNanTailDoesNotEraseGoodFrame(testCase)
    [~, sf, tow] = BCNAV2decoding([localFrame(300), nan(1, 100)]);
    verifyEqual(testCase, sf, 1);
    verifyEqual(testCase, tow, 300);
end

function testReacquisitionKeepsSeparateTimeAnchors(testCase)
    track = struct('I_P', [localFrame(300), zeros(1, 5), localFrame(306)], ...
        'trk_state', uint8([3*ones(1, 3000), 9*ones(1, 5), 3*ones(1, 3000)]));
    [~, segments] = decodeEphWithReacqResync(track);
    verifyEqual(testCase, numel(segments), 2);
    if numel(segments) == 2
        verifyEqual(testCase, [segments.indexStart], [1 3006]);
        verifyEqual(testCase, [segments.indexEnd], [3000 6005]);
        verifyEqual(testCase, [segments.TOW], [300 306]);
        time = trackingTimestampsFromSegments(6005, segments, 0.001);
        verifyEqual(testCase, time([1 3000 3006 6005]), ...
            [300 302.999 306 308.999], 'AbsTol', 1e-10);
        verifyTrue(testCase, all(isnan(time(3001:3005))));
    end
end

function testUnknownTimeRemainsUnknown(testCase)
    time = trackingTimestampsFromSegments(5, [], 0.001);
    verifyTrue(testCase, all(isnan(time)));
end

function testMissingTailNotMarkedAsLocked(testCase)
    track = struct('I_P', [localFrame(300), nan(1, 100)], ...
        'trk_state', uint8([3*ones(1, 3000), zeros(1, 100)]));
    [~, segments] = decodeEphWithReacqResync(track);
    verifyEqual(testCase, numel(segments), 1);
    if numel(segments) == 1
        verifyEqual(testCase, segments.indexEnd, 3000);
    end
end

function signal = localFrame(tow)
    payload = zeros(1, 264);
    payload(1:6) = dec2bin(11, 6) - '0';
    payload(7:12) = dec2bin(10, 6) - '0';
    payload(13:30) = dec2bin(tow/3, 18) - '0';
    crc = comm.CRCGenerator([24 23 18 17 14 11 10 7 6 5 4 3 1 0]);
    encoded = double(crc(payload.')).';
    preamble = [-1 -1 -1 1 1 1 -1 1 1 -1 1 1 -1 -1 1 -1 -1 -1 -1 1 -1 1 1 1];
    symbols = [preamble, 1 - 2*encoded, ones(1, 288)];
    signal = kron(symbols, [1 1 1 -1 1]);
end
