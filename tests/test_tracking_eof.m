function tests = test_tracking_eof
% Exercise real single-channel tracking against deliberately truncated IQ.
    tests = functiontests(localfunctions);
end

function testTruncatedIqKeepsOnlyCompletedEpochs(testCase)
    outDir = tempname;
    mkdir(outDir);
    cleanup = onCleanup(@() rmdir(outDir, 's'));
    settings = initSettings('resultRoot', outDir, 'tempdataSvPth', outDir);
    settings.filePath = outDir;
    settings.fileName = 'short_iq.dat';
    settings.dataType = 'int16';
    settings.fileType = 2;
    settings.size_per_sample = 4;
    settings.samplingFreq = 25e6;
    settings.skipNumberOfBytes = 0;
    settings.msToProcess = 5;
    settings.EnablePB = false;
    settings.FLL.enable = false;
    settings.KF.enable = false;
    settings.carrierAidCode = false;
    settings.longCoh_ms = 1;
    settings.TrkCN0Th = 0;
    fid = fopen(fullfile(outDir, settings.fileName), 'wb');
    % Two full code periods and an odd number of trailing I/Q values.
    fwrite(fid, int16(100*cos((1:100203)*0.13)), 'int16');
    fclose(fid);
    channel = struct('PRN', 11, 'codePhase', 1, 'acquiredFreq', 0, ...
        'status', 'T', 'polarityRef', 1, 'weilPhase', 0);
    track = trackOneChannel(channel, settings);
    verifyEqual(testCase, track.Nsize, 2);
    verifyEqual(testCase, numel(track.I_P), 2);
    verifyTrue(testCase, all(isfinite(track.absoluteSample)));
    saved = load(fullfile(outDir, 'Trk_Prn_11_001.mat'), 'chunk');
    verifyEqual(testCase, saved.chunk.Nsize, 2);
    verifyEqual(testCase, numel(saved.chunk.I_P), 2);
    verifyTrue(testCase, all(isnan(track.Timestamp)));
end

function testFullyBlankedEpochDoesNotBreakCodeLoop(testCase)
    outDir = tempname;
    mkdir(outDir);
    cleanup = onCleanup(@() rmdir(outDir, 's'));
    settings = initSettings('resultRoot', outDir, 'tempdataSvPth', outDir);
    settings.filePath = outDir;
    settings.fileName = 'blank_iq.dat';
    settings.dataType = 'int16';
    settings.fileType = 2;
    settings.size_per_sample = 4;
    settings.samplingFreq = 25e6;
    settings.skipNumberOfBytes = 0;
    settings.msToProcess = 5;
    settings.EnablePB = false;
    settings.FLL.enable = false;
    settings.KF.enable = false;
    settings.carrierAidCode = false;
    settings.longCoh_ms = 1;
    fid = fopen(fullfile(outDir, settings.fileName), 'wb');
    fwrite(fid, zeros(1, 300000, 'int16'), 'int16');
    fclose(fid);
    channel = struct('PRN', 11, 'codePhase', 1, 'acquiredFreq', 0, ...
        'status', 'T', 'polarityRef', 1, 'weilPhase', 0);
    track = trackOneChannel(channel, settings);
    verifyEqual(testCase, track.Nsize, 5);
    verifyTrue(testCase, all(isfinite(track.codeFreq)));
    verifyTrue(testCase, all(isfinite(track.dllDiscrFilt)));
    verifyTrue(testCase, all(isnan(track.dllDiscr)));
end
