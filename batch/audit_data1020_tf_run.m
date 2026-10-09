function result = audit_data1020_tf_run(action, varargin)
%AUDIT_DATA1020_TF_RUN Shared audits for independently resumed DATA1020 runs.
%   audit_data1020_tf_run('filter', settings, runDir)
%   audit_data1020_tf_run('conditions', baseline, settings, jsonPath)
%   audit_data1020_tf_run('completed', runDir, baseline, elapsedSeconds)
%
% The original batch's output schemas are retained. This helper does not run
% acquisition, tracking, navigation, or plotting, and never starts a pool.
% Its filter check uses a small deterministic synthetic vector and the same
% independent direct-convolution reference as run_data1020_tf_pairs.
    switch lower(char(action))
        case 'filter'
            assert(numel(varargin)==2,'Expected settings and run directory.');
            result=validateFilter(varargin{1}, ...
                fullfile(char(varargin{2}),'filter_verification.json'));
        case 'conditions'
            assert(numel(varargin)==3,'Expected baseline, settings, and JSON path.');
            result=compareSettings(varargin{1},varargin{2},char(varargin{3}));
        case 'completed'
            assert(numel(varargin)==3,'Expected run directory, baseline, and elapsed seconds.');
            result=auditCompleted(char(varargin{1}),varargin{2},varargin{3});
        otherwise
            error('audit_data1020_tf_run:Action','Expected filter, conditions, or completed.');
    end
end

function v=auditCompleted(dst,baseline,elapsedSeconds)
    assert(isnumeric(elapsedSeconds)&&isscalar(elapsedSeconds)&& ...
        isfinite(elapsedSeconds)&&elapsedSeconds>=0,'Invalid elapsed seconds.');
    try
        report=jsondecode(fileread(fullfile(dst,'report.json')));
        assert(isfield(report,'ok')&&report.ok,'Receiver report is not successful.');
        assert(strcmp(report.stage,'done'),'Receiver report has not reached done.');
        v=audit(dst,report,baseline);
        actual=load(fullfile(dst,'ui_results.mat'),'settings');
        compareSettings(baseline,actual.settings,fullfile(dst,'condition_verification.json'));
        assert(v.pipelineOk,'Receiver failed: %s',v.error);
        assert(isequal(reshape(v.searchedPrns,1,[]),1:63), ...
            'The completed experiment must search PRN 1:63 in baseline order.');
        assert(v.nAcquired==numel(v.acquiredPrns), ...
            'Report acquired count differs from saved acquisition results.');
        assert(v.allAcquiredTracked,'Not all acquired satellites have matching final tracking files.');
        assert(v.thresholdMatchesBaseline,'TF detector threshold differs from static-PB baseline.');
        assert(actual.settings.PB_settings.Th_static==baseline.PB_settings.Th_static, ...
            'PB calibration metadata changed.');
        assert(actual.settings.PB_settings.Th_static_tracking==baseline.PB_settings.Th_static_tracking, ...
            'PB tracking calibration metadata changed.');
        assert(strcmp(actual.settings.Frontend.mode,'tf_v1'), ...
            'Completed run must use TFBlankerV1.');
        assert(~actual.settings.EnablePB,'Time-domain PB must be disabled for the TF treatment.');
        assert(actual.settings.Frontend.TF.stopbandWidthHz==800e3, ...
            'Completed TF stopband must be 800 kHz.');
        assert(actual.settings.Frontend.TF.actualTriangleSpanUs==3, ...
            'Completed TF triangle span must be 3 microseconds.');
        v.elapsedSeconds=elapsedSeconds;
        writeJson(fullfile(dst,'validation.json'),v);
    catch ME
        v=struct('pipelineOk',false,'error',getReport(ME,'extended','hyperlinks','off'), ...
            'elapsedSeconds',elapsedSeconds);
        writeJson(fullfile(dst,'validation.json'),v);
        rethrow(ME)
    end
end

function r=compareSettings(a,b,path)
    allowed={'Frontend','EnablePB','parMaxWorkers','tag','outDir', ...
        'resultRoot','tempdataSvPth','useParfor','useParallelAcquisition'};
    fields=union(fieldnames(a),fieldnames(b)); changed={}; forbidden={};
    for k=1:numel(fields)
        f=fields{k};
        equal=isfield(a,f)&&isfield(b,f)&&isequaln(a.(f),b.(f));
        if ~equal
            changed{end+1}=f; %#ok<AGROW>
            if ~ismember(f,allowed), forbidden{end+1}=f; end %#ok<AGROW>
        end
    end
    r=struct('onlyAllowedChanges',isempty(forbidden),'changedFields',{changed}, ...
        'allowedFields',{allowed},'forbiddenFields',{forbidden}, ...
        'note',['Frontend/EnablePB are the treatment; paths/tags are output metadata; ' ...
        'worker count and parallel flags affect scheduling only.']);
    writeJson(path,r);
    assert(isempty(forbidden),'Non-treatment settings changed: %s',strjoin(forbidden,', '));
end

function r=validateFilter(cfg,path)
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
    assert(rel<1e-11&&all(meta.valid),'TF differs from independent direct convolution.');
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
    v.allAcquiredTracked=~isempty(v.tracks)&& ...
        isequal(sort(v.acquiredPrns(:)),sort([v.tracks.PRN].'));
    v.thresholdMatchesBaseline=s.Frontend.TF.effectiveThresholdAmplitude==baseline.PB_settings.Th_static_tracking;
    v.trackingPlotCount=numel(dir(fullfile(dst,'figures','trkResult','*.png')));
    v.navigationPlotCount=numel(dir(fullfile(dst,'figures','navResult','*.png')));
end

function writeJson(path,value)
    parent=fileparts(path); if ~isfolder(parent), mkdir(parent); end
    fid=fopen(path,'w','n','UTF-8'); assert(fid>0,'Cannot write %s',path);
    cleaner=onCleanup(@() fclose(fid));
    fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
