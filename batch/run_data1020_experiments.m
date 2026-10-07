function run_data1020_experiments(action, outputRoot, indices)
%RUN_DATA1020_EXPERIMENTS Reproducible static-PB processing of seven BJ files.
% prepare: sample each file, freeze its adaptive amplitude threshold, write configs.
% smoke: 5 s / PRN 27,33,38,41; full: PRN 1:63, all available time minus 1 s.
% Existing completed runs are skipped; incomplete output directories are refused.
    if nargin < 3, indices = 1:7; end
    projectRoot = fileparts(fileparts(mfilename('fullpath')));
    cd(projectRoot); setupPaths;
    outputRoot = char(outputRoot);
    if strcmp(action,'prepare')
        assert(~isfolder(outputRoot),'Output folder already exists.');
        mkdir(outputRoot);
        prepareCases(outputRoot);
        return
    end
    cases = jsondecode(fileread(fullfile(outputRoot,'cases.json')));
    runtime = struct('matlabVersion',version,'computer',computer, ...
        'projectRoot',projectRoot,'startedUtc',char(datetime('now','TimeZone','UTC')), ...
        'correlatorMex',which('correlateB2aMs_mex'), ...
        'pulseBlankerMex',which('pulseBlank_core_mex'));
    writeJson(fullfile(outputRoot,[action '_runtime.json']),runtime);
    oldVisible = get(groot,'defaultFigureVisible');
    set(groot,'defaultFigureVisible','off');
    visibleCleanup = onCleanup(@() set(groot,'defaultFigureVisible',oldVisible));
    for k = reshape(indices,1,[])
        item = cases(k);
        cfg = jsondecode(fileread(item.configPath));
        if strcmp(action,'smoke')
            cfg.msToProcess = 5000;
            cfg.acqSatelliteList = [27 33 38 41];
            cfg.numberOfChannels = 4;
            cfg.doNavigation = false;
            cfg.doNmea = false;
        else
            assert(strcmp(action,'full'),'Expected prepare, smoke, or full.');
            cfg.useParallelAcquisition=true;
        end
        cfg.tag = sprintf('%s_%02d_%s',action,k,item.id);
        runDir = fullfile(outputRoot,cfg.tag);
        donePath = fullfile(runDir,'validation.json');
        if isfile(donePath)
            prior = jsondecode(fileread(donePath));
            if prior.pipelineOk
                fprintf('Already complete: %s\n',runDir); continue
            end
        end
        assert(~isfolder(runDir),'Incomplete output exists; inspect before retry: %s',runDir);
        mkdir(runDir);
        diary(fullfile(runDir,'matlab.log'));
        started = tic;
        try
            report = runFromJsonConfig(cfg,'outDir',runDir, ...
                'openBaiduBrowser',false,'closeFigures',true);
            validation = auditRun(runDir,report);
            validation.elapsedSeconds = toc(started);
            writeJson(donePath,validation);
        catch ME
            validation = struct('pipelineOk',false,'error', ...
                getReport(ME,'extended','hyperlinks','off'),'elapsedSeconds',toc(started));
            writeJson(donePath,validation);
            fprintf(2,'%s\n',validation.error);
        end
        diary off
        fprintf('CASE %d %s: pipelineOk=%d elapsed=%.1f s\n', ...
            k,action,validation.pipelineOk,validation.elapsedSeconds);
        summarizeRuns(outputRoot,action,cases);
    end
    writeJson(fullfile(outputRoot,[action '_completion.json']), ...
        struct('indices',indices,'finishedUtc',char(datetime('now','TimeZone','UTC'))));
end

function prepareCases(root)
    inputDir = 'F:/Data/DME_BDSB2a/Experiment/2022BJ/DATA1020';
    names = {'data_1020_HUR.bin','data_1020_beiqijiatai.bin', ...
        'data_1020_HUR_1.bin','data_1020_HUR_2.bin', ...
        '200sData_@103330_221020@_1175400000_20000000_30_20000000_ZeroIF.bin', ...
        '200sData_@103801_221020@_1175400000_20000000_30_20000000_ZeroIF.bin', ...
        '300sData_@111407_221020@_1176450000_20000000_0_20000000_ZeroIF.bin'};
    ids = {'HUR','beiqijiatai','HUR_1','HUR_2','103330','103801','111407'};
    fc = [repmat(1176.45e6,1,4) 1175.4e6 1175.4e6 1176.45e6];
    gains = [30 30 30 30 30 30 0];
    fs = 20e6; pfa = 1e-4; scaleK = -94.72;
    mkdir(fullfile(root,'configs')); mkdir(fullfile(root,'probes'));
    cases = struct([]);
    for k = 1:7
        file = fullfile(inputDir,names{k}); info = dir(file);
        assert(isscalar(info),'Input missing or ambiguous: %s',file);
        duration = info.bytes/(4*fs);
        fid = fopen(file,'rb','ieee-le'); assert(fid>0,'Cannot open input.');
        cleaner = onCleanup(@() fclose(fid));
        offsets = unique([0 .05 linspace(1,duration-.02,19)]);
        thresholds = zeros(size(offsets)); clips = thresholds;
        q = zeros(numel(offsets),4); amplitudes = cell(size(offsets));
        for j = 1:numel(offsets)
            fseek(fid,4*floor(offsets(j)*fs),'bof');
            v = fread(fid,[2 round(.01*fs)],'int16=>double');
            assert(size(v,2)==round(.01*fs),'Incomplete probe.');
            a = hypot(v(1,:),v(2,:)); amplitudes{j} = a;
            % Exactly the receiver's complex adaptive-PB estimator, Pfa=1e-4.
            thresholds(j) = mean(a)*sqrt(2/pi)*sqrt(-2*log(pfa));
            clips(j) = mean(any(v == -32768 | v == 32767,1));
            q(j,:) = prctile(a,[50 90 99 99.9]);
        end
        clear cleaner
        threshold = median(thresholds);
        assert(isfinite(threshold) && threshold>0,'Invalid calibration.');
        duty = cellfun(@(a) mean(a>threshold),amplitudes);
        dbm = 20*log10(threshold)+scaleK+gains(k)-10*log10(fs);
        probe = struct('file',file,'bytes',info.bytes,'modified',info.date, ...
            'durationSeconds',duration,'samplingFreq',fs,'centerFreq',fc(k), ...
            'gain',gains(k),'dataType','int16','iqOrder','I+jQ little-endian', ...
            'probeOffsetsSeconds',offsets,'windowSeconds',.01, ...
            'dynamicThresholds',thresholds,'frozenAmplitudeThreshold',threshold, ...
            'thresholdDbmUsingScaleK',dbm,'scaleK',scaleK,'falseAlert',pfa, ...
            'staticBlankingDuty',duty,'clippedFraction',clips, ...
            'amplitudeQuantilePercentiles',[50 90 99 99.9],'amplitudeQuantiles',q, ...
            'method','Median of 21 window thresholds from receiver adaptive-PB formula; frozen for acquisition and tracking.');
        writeJson(fullfile(root,'probes',[ids{k} '.json']),probe);
        fig = figure('Visible','off','Color','w','Position',[100 100 1100 700]);
        tiledlayout(2,1);
        nexttile; plot(offsets,q,'-o'); hold on; yline(threshold,'k--','Static PB');
        plot(offsets,thresholds,'k:'); grid on;
        ylabel('ADC magnitude'); title(names{k},'Interpreter','none');
        legend('50%','90%','99%','99.9%','Frozen threshold','Adaptive estimates','Location','best');
        nexttile; plot(offsets,100*duty,'-o'); grid on;
        xlabel('File time (s)'); ylabel('Blanked samples (%)');
        exportgraphics(fig,fullfile(root,'probes',[ids{k} '.png']),'Resolution',130); close(fig);
        cfg = struct('filePath',inputDir,'fileName',names{k},'dataType','int16', ...
            'fileType',2,'machineFormat','ieee-le','samplingFreq',fs, ...
            'IF',1176.45e6-fc(k),'IFBandwidth',20e6, ...
            'usrp',struct('scaleK',scaleK,'gain',gains(k)), ...
            'skipNumberOfBytes',0,'msToProcess',floor(duration*1000)-1000, ...
            'numberOfChannels',63,'acqSatelliteList',1:63,'acqSearchBand',6000, ...
            'acqStep',125,'acqThreshold',1.6,'coarseNoncohMs',5,'fineNoncoh',5, ...
            'EnablePB',true,'Frontend',struct('mode','pb'), ...
            'Th_static_dBm',dbm,'Th_static_tracking_dBm',dbm, ...
            'PB_settings',struct('UseStatic',true,'Th_static',threshold, ...
                'Th_static_tracking',threshold,'falseAlert',pfa,'Th_TTL',5,'debugplot',false), ...
            'TrkCN0Th',25,'CNo_Th',30,'reacqCnoRecoverDbHz',30, ...
            'useParfor',true,'parMaxWorkers',6, ...
            'doNavigation',true,'doPlot',true,'plotTracking',true, ...
            'doNmea',true,'doBaiduMap',false,'plotBaiduMap',false);
        cfgPath = fullfile(root,'configs',sprintf('%02d_%s.json',k,ids{k}));
        writeJson(cfgPath,cfg);
        entry = struct('id',ids{k},'file',file,'configPath',cfgPath, ...
            'durationSeconds',duration,'requestedMs',cfg.msToProcess, ...
            'thresholdAmplitude',threshold,'IF',cfg.IF,'gain',gains(k));
        if isempty(cases), cases=entry; else, cases(k)=entry; end
        fprintf('PREPARED %d %s %.6fs IF=%.0f PB=%.6f ADC duty median=%.4f%%\n', ...
            k,ids{k},duration,cfg.IF,threshold,100*median(duty));
    end
    writeJson(fullfile(root,'cases.json'),cases);
end

function v = auditRun(runDir,report)
    v = struct('pipelineOk',logical(report.ok),'stage',report.stage, ...
        'error',report.error,'nAcquired',report.nAcquired, ...
        'nFixes',report.navSummary.nFixes,'requestedMs',report.requestedMs, ...
        'effectiveMs',report.effectiveMs,'tracks',struct([]));
    if ~report.ok, return; end
    S = load(fullfile(runDir,'ui_results.mat'));
    if isfield(S,'settings')
        settings = S.settings;
    else
        settings = S.results.settings;
    end
    writeJson(fullfile(runDir,'effective_settings.json'),settings);
    acq=S.results.acqResults;
    detected=acquisitionDetectedMask(acq);
    v.acquiredPrns=settings.acqSatelliteList(detected);
    metrics=table(settings.acqSatelliteList(:),detected(:), ...
        acq.peakMetric(:),acq.carrFreq(:),acq.codePhase(:), ...
        'VariableNames',{'PRN','detected','peakMetric','carrierWipeoffHz','codePhaseSamples'});
    writetable(metrics,fullfile(runDir,'acquisition_summary.csv'));
    files = dir(fullfile(runDir,'temp','Trk_Prn_*_final.mat'));
    for k = 1:numel(files)
        T = load(fullfile(files(k).folder,files(k).name),'finalTRes'); t = T.finalTRes;
        st = double(t.trk_state(:));
        locked = ismember(st,[3 4]);
        edges = diff([false;locked;false]);
        lengths = find(edges==-1)-find(edges==1);
        if isempty(lengths), longest = 0; else, longest = max(lengths); end
        cno = t.B2a_CNo(isfinite(t.B2a_CNo) & t.B2a_CNo>0);
        eta = t.eta(isfinite(t.eta));
        row = struct('PRN',t.PRN,'recordedMs',numel(t.I_P), ...
            'validMs',nnz(isfinite(t.I_P) & isfinite(t.absoluteSample)), ...
            'longStateMs',nnz(locked),'longestLongStateMs',longest, ...
            'reacqMs',nnz(st==9),'reacqEpisodes',nnz(diff([false;st==9])==1), ...
            'medianB2aCno',median(cno),'medianPbDuty',median(eta), ...
            'firstSample',t.absoluteSample(1),'lastSample',t.absoluteSample(end), ...
            'monotonicSamples',all(diff(t.absoluteSample)>0));
        if isempty(v.tracks), v.tracks=row; else, v.tracks(k)=row; end
    end
    if ~isempty(v.tracks)
        writetable(struct2table(v.tracks),fullfile(runDir,'tracking_summary.csv'));
    end
    v.pngCount = numel(dir(fullfile(runDir,'figures','**','*.png')));
    v.staticPbVerified = settings.PB_settings.UseStatic && ...
        strcmp(settings.Frontend.mode,'pb') && ...
        settings.PB_settings.Th_static==settings.PB_settings.Th_static_tracking;
    v.searchedPrns = settings.acqSatelliteList;
    v.meanLat = report.navSummary.meanLat; v.meanLon = report.navSummary.meanLon;
    v.meanHeight = report.navSummary.meanH;
    v.allAcquiredTracked=isequal(sort(v.acquiredPrns(:)),sort([v.tracks.PRN].'));
    v.allTracksReachedRequestedMs=all([v.tracks.recordedMs]>=settings.msToProcess);
    v.trackingPlotCount=numel(dir(fullfile(runDir,'figures','trkResult','*.png')));
    v.navigationPlotCount=numel(dir(fullfile(runDir,'figures','navResult','*.png')));
end

function summarizeRuns(root,action,cases)
    rows = struct([]);
    for k = 1:numel(cases)
        path = fullfile(root,sprintf('%s_%02d_%s',action,k,cases(k).id),'validation.json');
        r = struct('caseIndex',k,'id',cases(k).id,'status','pending', ...
            'acquired',NaN,'fixes',NaN,'effectiveSeconds',NaN,'elapsedSeconds',NaN);
        if isfile(path)
            v = jsondecode(fileread(path));
            if v.pipelineOk, r.status='done'; else, r.status='failed'; end
            if isfield(v,'nAcquired'), r.acquired=v.nAcquired; end
            if isfield(v,'nFixes'), r.fixes=v.nFixes; end
            if isfield(v,'effectiveMs'), r.effectiveSeconds=v.effectiveMs/1000; end
            r.elapsedSeconds = v.elapsedSeconds;
        end
        if isempty(rows), rows=r; else, rows(k)=r; end
    end
    writeJson(fullfile(root,[action '_summary.json']),rows);
    writetable(struct2table(rows),fullfile(root,[action '_summary.csv']));
end

function writeJson(path,value)
    fid = fopen(path,'w','n','UTF-8'); assert(fid>0,'Cannot write %s',path);
    cleaner = onCleanup(@() fclose(fid));
    fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
