function audit = audit_semiphysical_run(outputDir)
%AUDIT_SEMIPHYSICAL_RUN Check the actual settings and PRN 11 SDR products.
    outputDir = char(outputDir);
    audit = struct('ok', false, 'outputDir', outputDir, 'issues', {{}});
    try
        report = jsondecode(fileread(fullfile(outputDir, 'report.json')));
        requested = jsondecode(fileread(fullfile(outputDir, 'ui_config.json')));
        stored = load(fullfile(outputDir, 'ui_results.mat'), 'settings');
        settings = stored.settings;
        localWriteJson(fullfile(outputDir, 'effective_settings.json'), settings);
        audit.pipelineOK = report.ok && strcmp(report.stage, 'done');
        audit.navigationFixes = report.navSummary.nFixes;
        ignored = {'outDir', 'tag', 'doNavigation', 'doPlot', 'doNmea', 'doBaiduMap'};
        audit.configDifferences = localDifferences(requested, settings, '', ignored);
        if ~audit.pipelineOK
            audit.issues{end+1} = ['Pipeline: ' report.stage ' ' report.error];
        end
        if ~isempty(audit.configDifferences)
            audit.issues{end+1} = 'Requested and effective settings differ.';
        end
        if audit.navigationFixes == 0
            audit.issues{end+1} = 'No valid navigation time/position fixes.';
        end
        finalPath = fullfile(outputDir, 'temp', 'Trk_Prn_11_final.mat');
        saved = load(finalPath, 'finalTRes');
        tr = saved.finalTRes;
        audit.requestedMs = requested.msToProcess;
        audit.effectiveMs = settings.msToProcess;
        audit.prn11Samples = numel(tr.I_P);
        audit.prn11FiniteSamples = nnz(isfinite(tr.I_P) & isfinite(tr.absoluteSample));
        audit.prn11ReacqMs = nnz(tr.trk_state == 9);
        audit.prn11TimestampSamples = nnz(isfinite(tr.Timestamp));
        cno = tr.B2a_CNo(isfinite(tr.B2a_CNo) & tr.B2a_CNo > 0);
        audit.prn11MedianCNo = median(cno);
        audit.prn11ChunkSamples = 0;
        chunks = dir(fullfile(outputDir, 'temp', 'Trk_Prn_11_*.mat'));
        chunks = chunks(~cellfun('isempty', regexp({chunks.name}, ...
            '^Trk_Prn_11_\d+\.mat$', 'once')));
        audit.prn11Chunks = numel(chunks);
        for k = 1:numel(chunks)
            chunkFile = load(fullfile(chunks(k).folder, chunks(k).name), 'chunk');
            audit.prn11ChunkSamples = audit.prn11ChunkSamples + numel(chunkFile.chunk.I_P);
        end
        if audit.prn11Samples ~= settings.msToProcess || ...
                audit.prn11ChunkSamples ~= audit.prn11Samples || ...
                audit.prn11FiniteSamples ~= audit.prn11Samples
            audit.issues{end+1} = 'PRN 11 tracking/chunks do not cover the requested interval.';
        end
        if audit.prn11TimestampSamples == 0
            audit.issues{end+1} = 'PRN 11 has no decoded TOW timestamps.';
        end
        audit.nmeaExists = isfile(fullfile(outputDir, settings.nmea.fileName));
        if settings.nmea.enable && ~audit.nmeaExists
            audit.issues{end+1} = 'Requested NMEA output is missing.';
        end
        audit.ok = isempty(audit.issues);
    catch ME
        audit.issues{end+1} = [ME.identifier ': ' ME.message];
    end
    localWriteJson(fullfile(outputDir, 'validation.json'), audit);
end

function differences = localDifferences(expected, actual, prefix, ignored)
    differences = {};
    names = fieldnames(expected);
    for k = 1:numel(names)
        name = names{k};
        if isempty(prefix) && ismember(name, ignored), continue; end
        path = [prefix name];
        if ~isfield(actual, name)
            differences{end+1} = path; %#ok<AGROW>
            continue;
        end
        a = actual.(name); e = expected.(name);
        if isstruct(e) && isstruct(a)
            differences = [differences, localDifferences(e, a, [path '.'], {})]; %#ok<AGROW>
        elseif isempty(e) && isnumeric(a) && isscalar(a) && isnan(a)
            % JSON null represents the NaN reference position.
        elseif (isnumeric(e) || islogical(e)) && (isnumeric(a) || islogical(a))
            if numel(e) ~= numel(a) || ...
                    ~all(abs(double(a(:))-double(e(:))) <= 1e-10*max(1,abs(double(e(:)))))
                differences{end+1} = path; %#ok<AGROW>
            end
        elseif ~isequaln(e, a)
            differences{end+1} = path; %#ok<AGROW>
        end
    end
end

function localWriteJson(path, value)
    fid = fopen(path, 'w', 'n', 'UTF-8');
    assert(fid >= 0, 'Cannot write %s', path);
    cleanup = onCleanup(@() fclose(fid));
    fprintf(fid, '%s\n', jsonencode(value, 'PrettyPrint', true));
end
