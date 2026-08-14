function tests = test_track_result_serialization
%TEST_TRACK_RESULT_SERIALIZATION Guard memory-safe tracking persistence.
    tests = functiontests(localfunctions);
end

function setupOnce(testCase)
    setupPaths();
    outDir = tempname;
    mkdir(outDir);
    testCase.TestData.outDir = outDir;
end

function teardownOnce(testCase)
    outDir = testCase.TestData.outDir;
    if exist(outDir, 'dir')
        rmdir(outDir, 's');
    end
end

function testStructChunksRoundTrip(testCase)
    outDir = testCase.TestData.outDir;
    settings = localSettings(outDir);

    source = TrackResults2(settings, 600);
    source.PRN = 22;
    source.I_P = 1:600;
    source.cur_state(:) = true;
    verifyTrue(testCase, source.save());

    source.I_P(1:400) = 601:1000;
    source.cur_state(1:400) = true;
    verifyTrue(testCase, source.partsave(settings, 400));

    firstPath = fullfile(outDir, 'Trk_Prn_22_001.mat');
    secondPath = fullfile(outDir, 'Trk_Prn_22_002.mat');
    localVerifyStructVariable(testCase, firstPath);
    localVerifyStructVariable(testCase, secondPath);

    first = load(firstPath, 'chunk');
    second = load(secondPath, 'chunk');
    merged = TrackResults2(settings, 1000);
    verifyGreaterThan(testCase, merged.copyFROM(first.chunk, 1), 0.9);
    verifyGreaterThan(testCase, merged.copyFROM(second.chunk, 601), 0.9);
    verifyEqual(testCase, merged.I_P, 1:1000);
    verifyTrue(testCase, all(merged.cur_state));
end

function testLightweightInactiveChannels(testCase)
    channels = TrackResults2.createEmptyArray(60);
    verifyEqual(testCase, numel(channels), 60);
    verifyTrue(testCase, all(arrayfun(@(value) isempty(value.I_P), channels)));
end

function testStructRestoresObject(testCase)
    settings = localSettings(testCase.TestData.outDir);
    source = TrackResults2(settings, 10);
    source.PRN = 36;
    source.I_P = 1:10;
    restored = TrackResults2.fromStruct(source.toStruct());
    verifyClass(testCase, restored, 'TrackResults2');
    verifyEqual(testCase, restored.PRN, 36);
    verifyEqual(testCase, restored.I_P, 1:10);
end

function localVerifyStructVariable(testCase, path)
    info = whos('-file', path);
    verifyEqual(testCase, numel(info), 1);
    verifyEqual(testCase, info.name, 'chunk');
    verifyEqual(testCase, info.class, 'struct');
end

function settings = localSettings(outDir)
    settings = struct( ...
        'msToProcess', 1000, ...
        'tempdataSvPth', outDir, ...
        'CNoInterval', 200);
end
