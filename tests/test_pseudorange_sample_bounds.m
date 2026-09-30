function tests = test_pseudorange_sample_bounds
% A channel may only contribute inside an actually recorded code period.
    tests = functiontests(localfunctions);
end

function setup(testCase)
    clear calculatePseudoranges
    testCase.TestData.settings = struct('numberOfChannels', 1, ...
        'codeFreqBasis', 10230e3, 'codeLength', 10230, ...
        'samplingFreq', 25e6, 'startOffset', 68.802, 'c', 299792458);
    testCase.TestData.track = struct('absoluteSample', [100 25100 50100], ...
        'codeFreq', repmat(10230e3, 1, 3), 'remCodePhase', zeros(1, 3), ...
        'trk_state', uint8([3 3 3]));
end

function testWithinRecordedPeriod(testCase)
    [pr, tx] = localEvaluate(testCase, 12600, inf);
    verifyTrue(testCase, isfinite(pr));
    verifyEqual(testCase, tx, 1000.0005, 'AbsTol', 1e-10);
end

function testBeforeFirstSample(testCase)
    [pr, tx] = localEvaluate(testCase, 99, inf);
    verifyTrue(testCase, isnan(pr));
    verifyFalse(testCase, isfinite(tx));
end

function testAfterLastRecordedPeriod(testCase)
    [pr, tx] = localEvaluate(testCase, 75100, inf);
    verifyTrue(testCase, isnan(pr));
    verifyFalse(testCase, isfinite(tx));
end

function testGapIsNotExtrapolated(testCase)
    testCase.TestData.track.absoluteSample = [100 NaN 50100];
    [pr, tx] = localEvaluate(testCase, 30000, inf);
    verifyTrue(testCase, isnan(pr));
    verifyFalse(testCase, isfinite(tx));
end

function testEarlierReplayResetsSearch(testCase)
    localEvaluate(testCase, 60000, inf);
    [~, tx] = localEvaluate(testCase, 12600, 1000.1);
    verifyEqual(testCase, tx, 1000.0005, 'AbsTol', 1e-10);
end

function [pr, tx] = localEvaluate(testCase, sample, localTime)
    [pr, tx] = calculatePseudoranges(testCase.TestData.track, 1, 1000, ...
        sample, localTime, 1, testCase.TestData.settings);
end
