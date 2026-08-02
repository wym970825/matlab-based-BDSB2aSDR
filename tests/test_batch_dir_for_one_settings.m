function result = test_batch_dir_for_one_settings()
%TEST_BATCH_DIR_FOR_ONE_SETTINGS Fast orchestration tests (no SDR run).

    setupPaths();
    root = fullfile(tempdir, ['b2a_batch_test_' char(string( ...
        datetime('now'), 'yyMMdd_HHmmss_SSS'))]);
    inputDir = fullfile(root, 'input');
    nestedDir = fullfile(inputDir, 'nested');
    mkdir(nestedDir);
    cleanup = onCleanup(@() localCleanup(root));

    localTouch(fullfile(inputDir, 'b.bin'));
    localTouch(fullfile(inputDir, 'A.BIN'));
    localTouch(fullfile(inputDir, 'ignore.txt'));
    localTouch(fullfile(nestedDir, 'c.bin'));

    raw = struct('msToProcess', 1000, 'filePath', 'original', ...
        'fileName', 'original.bin', 'outDir', 'must_be_overridden', ...
        'tag', 'source_tag');
    jsonPath = fullfile(root, 'config.json');
    localWriteJson(jsonPath, raw);

    outJson = fullfile(root, 'out_json');
    jsonReport = batchDirForOneSettings(inputDir, jsonPath, ...
        'OutputRoot', outJson, 'DryRun', true, 'Tag', 'json_test');
    assert(jsonReport.ok);
    assert(jsonReport.nFiles == 2);
    assert(jsonReport.nPlanned == 2);
    assert(strcmp(jsonReport.items(1).fileName, 'A.BIN'));
    assert(strcmp(jsonReport.items(2).fileName, 'b.bin'));
    assert(numel(unique({jsonReport.items.outDir})) == 2);
    for i = 1:jsonReport.nFiles
        cfg = jsondecode(fileread(jsonReport.items(i).configPath));
        assert(strcmp(cfg.fileName, jsonReport.items(i).fileName));
        assert(strcmp(strrep(cfg.outDir, '\', '/'), ...
            strrep(jsonReport.items(i).outDir, '\', '/')));
    end
    sourceAfter = jsondecode(fileread(jsonPath));
    assert(strcmp(sourceAfter.fileName, raw.fileName));
    assert(strcmp(sourceAfter.outDir, raw.outDir));

    settings = raw;
    settings.originalMarker = 42;
    settingsBefore = settings;
    outSettings = fullfile(root, 'out_settings');
    settingsReport = batchDirForOneSettings(inputDir, settings, ...
        'OutputRoot', outSettings, 'DryRun', true, ...
        'Recursive', true, 'Tag', 'settings_test');
    assert(settingsReport.ok);
    assert(settingsReport.nFiles == 3);
    assert(settingsReport.nPlanned == 3);
    assert(isequaln(settings, settingsBefore));
    assert(all(strcmp({settingsReport.items.status}, 'planned')));

    outScript = fullfile(root, 'out_script');
    settingsSource = jsonPath;
    batchOptions = {'OutputRoot', outScript, 'DryRun', true, ...
        'Tag', 'script_test'};
    projectRoot = fileparts(fileparts(mfilename('fullpath')));
    assert(isfile(fullfile(projectRoot, 'batch', ...
        'batch-dir-ForOneSettings.m')));
    run(fullfile(projectRoot, 'batch', 'batch_dir_ForOneSettings.m'));
    assert(batchReport.ok);
    assert(batchReport.nPlanned == 2);

    result = struct('ok', true, 'jsonFiles', jsonReport.nFiles, ...
        'recursiveFiles', settingsReport.nFiles);
    fprintf('test_batch_dir_for_one_settings: PASS json=%d recursive=%d\n', ...
        result.jsonFiles, result.recursiveFiles);
end

function localTouch(path)
    fid = fopen(path, 'w');
    if fid < 0, error('test_batch:Create', 'Cannot create %s', path); end
    cleaner = onCleanup(@() fclose(fid));
    fwrite(fid, uint8(1:16), 'uint8');
end

function localWriteJson(path, value)
    fid = fopen(path, 'w', 'n', 'UTF-8');
    if fid < 0, error('test_batch:CreateJson', 'Cannot create %s', path); end
    cleaner = onCleanup(@() fclose(fid));
    fwrite(fid, jsonencode(value), 'char');
end

function localCleanup(root)
    if isfolder(root) && startsWith(lower(root), lower(tempdir))
        try
            rmdir(root, 's');
        catch
        end
    end
end
