function run_data1020_tf_pairs(manifestPath, action, indices)
%RUN_DATA1020_TF_PAIRS Replay matched experiments with only the TF frontend changed.
% Two process workers and invisible figures keep the desktop resource load low.
    setupPaths;
    if nargin<2, action='full'; end
    m=jsondecode(fileread(manifestPath));
    if nargin<3, indices=1:numel(m.entries); end
    assert(ismember(action,{'smoke','full'}),'Expected smoke or full.');
    set(groot,'defaultFigureVisible','off'); maxNumCompThreads(1);
    records=struct([]);
    for idx=reshape(indices,1,[])
        e=m.entries(idx);
        saved=load(fullfile(e.pbDir,'ui_results.mat'),'settings'); baseline=saved.settings;
        clear saved
        cfg=baseline;
        cfg.Frontend=struct('mode','tf_v1','TF',struct( ...
            'centerHz',e.station.frequencyHz-e.centerFrequencyHz, ...
            'stopbandWidthHz',800e3,'triangleSpanUs',3));
        cfg.EnablePB=false;
        cfg.parMaxWorkers=2;
        if strcmp(action,'full')
            dst=e.tfDir;
        else
            dst=fullfile(m.outputRoot,'smoke_tf',sprintf('%02d_%s',e.experimentNumber,e.sourceId));
            cfg.msToProcess=5000; cfg.acqSatelliteList=[38 41]; cfg.numberOfChannels=2;
            cfg.doNavigation=false; cfg.doNmea=false;
        end
        [~,cfg.tag]=fileparts(dst); cfg.outDir=dst;
        cfg.resultRoot=dst; cfg.tempdataSvPth=fullfile(dst,'temp');
        finalPath=fullfile(dst,'validation.json');
        if isfile(finalPath)
            prior=jsondecode(fileread(finalPath));
            if prior.pipelineOk, fprintf('TF pair already complete: %s\n',dst); continue; end
        end
        assert(~isfolder(dst),'Inspect incomplete output before retry: %s',dst);
        cfg=resolveFrontendSettings(initSettings(cfg));
        if strcmp(action,'full')
            compareSettings(baseline,cfg,fullfile(m.outputRoot,'configs',sprintf('%02d_condition_check.json',e.experimentNumber)));
        end
        assert(cfg.PB_settings.Th_static==baseline.PB_settings.Th_static);
        assert(cfg.PB_settings.Th_static_tracking==baseline.PB_settings.Th_static_tracking);
        assert(cfg.Frontend.TF.effectiveThresholdAmplitude==baseline.PB_settings.Th_static_tracking);
        if ~isfolder(dst), mkdir(dst); end
        writeJson(fullfile(dst,'comparison_origin.json'),struct('pbDir',e.pbDir, ...
            'station',e.station,'rfCenterHz',e.centerFrequencyHz, ...
            'tfDigitalCenterHz',cfg.Frontend.TF.centerHz, ...
            'resourceOnlyChange','parMaxWorkers: 6 to 2; figure windows disabled'));
        diary(fullfile(dst,'matlab.log')); started=tic;
        try
            validateFilter(cfg,fullfile(dst,'filter_verification.json'));
            report=runFromJsonConfig(cfg,'outDir',dst,'openBaiduBrowser',false,'closeFigures',true);
            v=audit(dst,report,baseline);
            if report.ok && strcmp(action,'full')
                actual=load(fullfile(dst,'ui_results.mat'),'settings');
                compareSettings(baseline,actual.settings,fullfile(dst,'condition_verification.json'));
                clear actual
            end
            v.elapsedSeconds=toc(started); writeJson(finalPath,v);
            assert(v.pipelineOk,'Receiver failed: %s',v.error);
            assert(v.allAcquiredTracked,'Not all acquired satellites were tracked.');
            assert(v.thresholdMatchesBaseline,'Threshold mismatch.');
        catch ME
            v=struct('pipelineOk',false,'error',getReport(ME,'extended','hyperlinks','off'), ...
                'elapsedSeconds',toc(started));
            writeJson(finalPath,v); diary off; rethrow(ME)
        end
        diary off; close all force;
        row=struct('experimentNumber',e.experimentNumber,'sourceId',e.sourceId, ...
            'path',dst,'ok',v.pipelineOk,'acquired',v.nAcquired,'fixes',v.nFixes, ...
            'elapsedSeconds',v.elapsedSeconds);
        if isempty(records), records=row; else, records(end+1)=row; end %#ok<AGROW>
        writeJson(fullfile(m.outputRoot,['tf_' action '_status.json']),records);
        fprintf('TF %s experiment %d completed: acquired=%d fixes=%d elapsed=%.1fs\n', ...
            action,e.experimentNumber,v.nAcquired,v.nFixes,v.elapsedSeconds);
        clear baseline cfg report v
    end
    writeJson(fullfile(m.outputRoot,['tf_' action '_completion.json']), ...
        struct('indices',indices,'completedAtUtc',char(datetime('now','TimeZone','UTC'))));
end

function compareSettings(a,b,path)
    allowed={'Frontend','EnablePB','parMaxWorkers','tag','outDir','resultRoot','tempdataSvPth'};
    fields=union(fieldnames(a),fieldnames(b)); changed={}; forbidden={};
    for k=1:numel(fields)
        f=fields{k};
        equal=isfield(a,f) && isfield(b,f) && isequaln(a.(f),b.(f));
        if ~equal
            changed{end+1}=f; %#ok<AGROW>
            if ~ismember(f,allowed), forbidden{end+1}=f; end %#ok<AGROW>
        end
    end
    writeJson(path,struct('onlyAllowedChanges',isempty(forbidden),'changedFields',{changed}, ...
        'allowedFields',{allowed},'forbiddenFields',{forbidden}, ...
        'note','Frontend/EnablePB are the treatment; paths/tags are output metadata; worker count only affects scheduling.'));
    assert(isempty(forbidden),'Non-treatment settings changed: %s',strjoin(forbidden,', '));
end

function validateFilter(cfg,path)
    filter=TFBlankerV1(cfg); t=filter.Config;
    stream=RandStream('mt19937ar','Seed',20261009); n=12000; k=0:n-1;
    x=.05*t.effectiveThresholdAmplitude*(randn(stream,1,n)+1i*randn(stream,1,n));
    pulse=5*t.effectiveThresholdAmplitude*exp(-.5*((k-6000)/25).^2);
    x=x+pulse.*exp(1i*2*pi*t.centerHz/cfg.samplingFreq*k);
    detector=abs(x)>=t.effectiveThresholdAmplitude;
    weights=conv(movmax(double(detector),[t.A t.A]),filter.Triangle,'same');
    expected=(1-weights).*x+weights.*conv(x,filter.Notch,'same');
    [actual,meta]=filter.applyRange(x,0,t.H,n-2*t.H);
    reference=expected(t.H+1:n-t.H);
    rel=max(abs(actual-reference))/max(abs(x));
    assert(rel<1e-11 && all(meta.valid),'TF differs from independent direct convolution.');
    r=struct('ok',true,'relativeErrorToDirectConvolution',rel,'samplingFreq',cfg.samplingFreq, ...
        'centerHz',t.centerHz,'stopbandWidthHz',t.stopbandWidthHz, ...
        'triangleSpanUs',t.actualTriangleSpanUs,'effectiveTaps',t.effectiveTaps, ...
        'thresholdAmplitude',t.effectiveThresholdAmplitude,'haloSamples',t.H, ...
        'worstStopbandDbOnGrid',filter.Info.worstStopbandDbOnGrid, ...
        'coefficientHash',filter.Info.coefficientHash);
    writeJson(path,r);
end

function v=audit(dst,report,baseline)
    v=struct('pipelineOk',logical(report.ok),'stage',report.stage,'error',report.error, ...
        'nAcquired',report.nAcquired,'nFixes',report.navSummary.nFixes, ...
        'requestedMs',report.requestedMs,'effectiveMs',report.effectiveMs,'tracks',struct([]));
    if ~report.ok, return; end
    S=load(fullfile(dst,'ui_results.mat'),'settings','results'); s=S.settings;
    writeJson(fullfile(dst,'effective_settings.json'),s);
    a=S.results.acqResults; detected=acquisitionDetectedMask(a);
    v.acquiredPrns=s.acqSatelliteList(detected); v.searchedPrns=s.acqSatelliteList;
    metrics=table(s.acqSatelliteList(:),detected(:),a.peakMetric(:),a.carrFreq(:),a.codePhase(:), ...
        'VariableNames',{'PRN','detected','peakMetric','carrierWipeoffHz','codePhaseSamples'});
    writetable(metrics,fullfile(dst,'acquisition_summary.csv'));
    files=dir(fullfile(dst,'temp','Trk_Prn_*_final.mat'));
    for k=1:numel(files)
        T=load(fullfile(files(k).folder,files(k).name),'finalTRes'); t=T.finalTRes;
        st=double(t.trk_state(:)); locked=ismember(st,[3 4]); edges=diff([false;locked;false]);
        lens=find(edges==-1)-find(edges==1); if isempty(lens), longest=0; else, longest=max(lens); end
        cno=t.B2a_CNo(isfinite(t.B2a_CNo)&t.B2a_CNo>0);
        row=struct('PRN',t.PRN,'recordedMs',numel(t.I_P),'longStateMs',nnz(locked), ...
            'longestLongStateMs',longest,'reacqMs',nnz(st==9), ...
            'reacqEpisodes',nnz(diff([false;st==9])==1),'medianB2aCno',median(cno), ...
            'firstSample',t.absoluteSample(1),'lastSample',t.absoluteSample(end));
        if isempty(v.tracks), v.tracks=row; else, v.tracks(end+1)=row; end %#ok<AGROW>
        clear T t
    end
    if ~isempty(v.tracks), writetable(struct2table(v.tracks),fullfile(dst,'tracking_summary.csv')); end
    v.allAcquiredTracked=isequal(sort(v.acquiredPrns(:)),sort([v.tracks.PRN].'));
    v.thresholdMatchesBaseline=s.Frontend.TF.effectiveThresholdAmplitude==baseline.PB_settings.Th_static_tracking;
    v.trackingPlotCount=numel(dir(fullfile(dst,'figures','trkResult','*.png')));
    v.navigationPlotCount=numel(dir(fullfile(dst,'figures','navResult','*.png')));
end

function writeJson(path,value)
    parent=fileparts(path); if ~isfolder(parent), mkdir(parent); end
    fid=fopen(path,'w','n','UTF-8'); assert(fid>0,'Cannot write %s',path);
    cleaner=onCleanup(@() fclose(fid)); fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
