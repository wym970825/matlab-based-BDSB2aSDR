function tests = test_nmea_sentences
%TEST_NMEA_SENTENCES Focused tests for generic NMEA builders and exporter.
    tests = functiontests(localfunctions);
end

function testZdaFieldsAndChecksum(testCase)
    sentence = nmeaBuildZDA('GN', '123519.00', 20, 9, 2023, 0, 0);
    verifyEqual(testCase, sentence(1:7), '$GNZDA,');
    verifyTrue(testCase, contains(sentence, ',20,09,2023,00,00*'));
    localVerifyChecksum(testCase, sentence);
end

function testGsaUsesOnlyPassedSatelliteIds(testCase)
    sentence = nmeaBuildGSA('GN', 'A', 3, [20 32 37 46], ...
        2.1, 1.2, 1.7, 4);
    verifyTrue(testCase, startsWith(sentence, ...
        '$GNGSA,A,3,20,32,37,46,'));
    verifyTrue(testCase, contains(sentence, ',2.1,1.2,1.7,4*'));
    localVerifyChecksum(testCase, sentence);
end

function testBuildersHaveGenericFallbackTalker(testCase)
    sentence = nmeaBuildGGA('', '000000.00', nan, nan, 0, 0, ...
        nan, nan, nan);
    verifyTrue(testCase, startsWith(sentence, '$GNGGA,'));
    localVerifyChecksum(testCase, sentence);
end

function testSatelliteIdsAbove99AreNotTruncated(testCase)
    gsa = nmeaBuildGSA('GN', 'A', 3, [12 301], 1, 1, 1, []);
    verifyTrue(testCase, contains(gsa, ',12,301,'));
    gsv = nmeaBuildGSV('GN', [12 301], [40 50], [100 200], [42 43]);
    verifyTrue(testCase, contains(gsv{1}, ',12,40,100,42,301,50,200,43'));
    localVerifyChecksum(testCase, gsa);
    localVerifyChecksum(testCase, gsv{1});
end

function testExportUsesRaimAndAbsoluteDate(testCase)
    tempDir = tempname;
    mkdir(tempDir);
    cleanup = onCleanup(@() rmdir(tempDir, 's')); %#ok<NASGU>

    nav = struct();
    nav.latitude = 26.5;
    nav.longitude = 107.5;
    nav.height = 900;
    nav.localTime = 3 * 86400 + 12 * 3600;
    nav.PRN = [20; 32; 37; 46; 58];
    nav.el = [30; 40; 50; 60; 70];
    nav.az = [10; 20; 30; 40; 50];
    nav.DOP = [2.5; 2.0; 1.2; 1.6; 0.9];
    nav.raim.usedPRN = {[20 32 37 46]};
    nav.raim.excludedPRN = {58};
    nav.raim.passed = true;
    eph = eph_structure_init();
    eph.WN = 924;

    settings = struct('navSolPeriod', 500, 'resultRoot', tempDir, ...
        'nmea', struct('enable', true, 'talkerId', 'GN', ...
        'utcOffsetSeconds', 4, 'weekEpoch', '2006-01-01', ...
        'systemId', 4, 'quality', 1, 'geoidSepM', 0, ...
        'fileName', 'test.nmea', 'emitGGA', true, 'emitGSA', true, ...
        'emitGSV', true, 'emitZDA', true));
    path = exportNmea(nav, settings, 'eph', eph, 'outDir', tempDir);
    text = fileread(path);
    gsa = regexp(text, '\$GNGSA[^\r\n]+', 'match', 'once');
    verifyTrue(testCase, contains(gsa, ',20,32,37,46,'));
    verifyFalse(testCase, contains(gsa, ',58,'));
    verifyTrue(testCase, contains(text, '$GNZDA,'));

    sentences = regexp(text, '\$[^\r\n]+', 'match');
    for idx = 1:numel(sentences)
        localVerifyChecksum(testCase, sentences{idx});
    end
end

function testExportSkipsZdaWithoutValidFix(testCase)
    tempDir = tempname;
    mkdir(tempDir);
    cleanup = onCleanup(@() rmdir(tempDir, 's')); %#ok<NASGU>
    nav = struct('latitude', nan, 'longitude', nan, 'height', nan, ...
        'localTime', 604796, 'PRN', zeros(4, 1), ...
        'el', nan(4, 1), 'az', nan(4, 1), 'DOP', zeros(5, 1));
    nav.raim.usedPRN = {[]};
    nav.raim.excludedPRN = {[]};
    nav.raim.passed = false;
    eph = eph_structure_init();
    eph.WN = 924;
    settings = struct('navSolPeriod', 500, 'resultRoot', tempDir, ...
        'nmea', struct('enable', true, 'talkerId', 'GN', ...
        'utcOffsetSeconds', 4, 'weekEpoch', '2006-01-01', ...
        'systemId', 4, 'quality', 1, 'geoidSepM', 0, ...
        'fileName', 'invalid.nmea', 'emitGGA', true, 'emitGSA', true, ...
        'emitGSV', true, 'emitZDA', true));
    path = exportNmea(nav, settings, 'eph', eph, 'outDir', tempDir);
    text = fileread(path);
    verifyTrue(testCase, contains(text, '$GNGGA,'));
    verifyTrue(testCase, contains(text, '$GNGSA,A,1,'));
    verifyFalse(testCase, contains(text, '$GNZDA,'));
end

function localVerifyChecksum(testCase, sentence)
    sentence = strtrim(sentence);
    star = find(sentence == '*', 1, 'last');
    verifyNotEmpty(testCase, star);
    verifyEqual(testCase, sentence(star + 1:star + 2), ...
        nmeaChecksum(sentence(2:star - 1)));
end
