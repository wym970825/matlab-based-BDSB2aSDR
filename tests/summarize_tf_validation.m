function entry=summarize_tf_validation(runDir,expectedMs)
%SUMMARIZE_TF_VALIDATION Read full tracking archive, not the lightweight UI MAT.
    report=jsondecode(fileread(fullfile(runDir,'report.json')));
    config=jsondecode(fileread(fullfile(runDir,'validation_config.json')));
    if nargin<2, expectedMs=config.msToProcess; end
    file=fullfile(runDir,['run_B2a_' report.tag '.mat']);
    loaded=load(file,'results'); tr=trackResultsToStruct(loaded.results.trackResults);
    tr=tr([tr.PRN]==11);
    assert(numel(tr)==1,'TFValidation:PRN','Missing or ambiguous PRN 11 output.');
    finite=all(isfinite(tr.absoluteSample)) && all(isfinite(tr.I_P));
    frontendComplete=all(tr.frontendValidCount==tr.frontendSampleCount) && ...
        all(tr.frontendSampleCount>0) && ~any(tr.frontendBoundaryFlag);
    [~,label]=fileparts(runDir);
    entry=struct('mode',label,'outDir',runDir,'pipelineOk',report.ok, ...
        'recordedMs',numel(tr.I_P),'complete',report.ok && numel(tr.I_P)==expectedMs && finite && frontendComplete, ...
        'reacqMs',nnz(tr.trk_state==9),'longStateFraction',mean(tr.cur_state), ...
        'firstSample',tr.absoluteSample(1),'lastSample',tr.absoluteSample(end), ...
        'frontendMode',tr.frontendInfo.mode,'frontendConfigHash',tr.frontendInfo.configHash, ...
        'meanWeight',mean(tr.frontendMeanWeight),'finiteS4',nnz(isfinite(tr.S4)));
    v=tr.PilotCNo(isfinite(tr.PilotCNo)&tr.PilotCNo>0); entry.medianPilotCNo=median(v);
    v=tr.B2a_CNo(isfinite(tr.B2a_CNo)&tr.B2a_CNo>0); entry.medianTotalCNo=median(v);
    normal=tr.trk_state(1:end-1)~=9 & tr.trk_state(2:end)~=9;
    delta=diff(tr.absoluteSample)-tr.frontendSampleCount(1:end-1);
    entry.maxNormalTimelineErrorSamples=max(abs(delta(normal)),[],'omitnan');
    entry.complete=entry.complete && all(delta(normal)==0);
    fid=fopen(fullfile(runDir,'validation_summary.json'),'w','n','UTF-8'); cl=onCleanup(@() fclose(fid));
    fprintf(fid,'%s\n',jsonencode(entry,'PrettyPrint',true));
end
