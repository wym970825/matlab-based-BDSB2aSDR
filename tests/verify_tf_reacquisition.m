function summary=verify_tf_reacquisition(outputRoot)
%VERIFY_TF_REACQUISITION Deliberate lock-alarm injection on real interfered IF.
% Changes TrkCN0Th only in this isolated control; never used for BW comparison.
    root=setupPaths();
    if nargin<1, outputRoot=fullfile(root,'results','upgrade_v020','forced_reacq'); end
    assert(~isfolder(outputRoot),'ReacqTest:OutputExists','Use a fresh output folder.');
    mkdir(outputRoot);
    cfg=jsondecode(fileread(fullfile(root,'docs','semiphysical_recompute','configs','04_2700_n50dBm.json')));
    cfg.msToProcess=2000; cfg.acqSatelliteList=11; cfg.numberOfChannels=1;
    cfg.useParfor=false; cfg.doNavigation=false; cfg.doPlot=false;
    cfg.doNmea=false; cfg.doBaiduMap=false; cfg.plotTracking=false;
    cfg.Frontend=struct('mode','tf_v1'); cfg.TrkCN0Th=80;
    cfg.tag='forced_reacq_not_scientific_comparison';
    path=fullfile(outputRoot,'validation_config.json');
    writeJson(path,cfg);
    captured=evalc('report=runFromJsonConfig(path,''outDir'',outputRoot,''closeFigures'',true,''openBaiduBrowser'',false);');
    fid=fopen(fullfile(outputRoot,'matlab.log'),'w','n','UTF-8'); fprintf(fid,'%s',captured); fclose(fid);
    assert(report.ok,'ReacqTest:Pipeline','Forced REACQ pipeline failed.');
    loaded=load(fullfile(outputRoot,['run_B2a_' cfg.tag '.mat']),'results');
    tr=trackResultsToStruct(loaded.results.trackResults);
    assert(numel(tr)==1 && numel(tr.I_P)==cfg.msToProcess);
    tokens=regexp(captured,'REACQ OK PRN\d+ @loop (\d+) sample (\d+)->(\d+) rewindSamples=(\d+)','tokens');
    assert(~isempty(tokens),'ReacqTest:NoHandover','The injected alarm did not exercise a successful handover.');
    evidence=zeros(numel(tokens),4);
    for k=1:numel(tokens)
        values=str2double(tokens{k}); epoch=values(1); before=values(2); after=values(3); rewind=values(4);
        assert(tr.trk_state(epoch)==9 && tr.trk_state(epoch+1)~=9);
        assert(before==tr.absoluteSample(epoch)+tr.frontendSampleCount(epoch));
        assert(after==tr.absoluteSample(epoch+1) && after==before-rewind);
        assert(rewind>=1 && rewind<=round(cfg.samplingFreq*.001));
        evidence(k,:)=values;
    end
    assert(all(tr.frontendValidCount==tr.frontendSampleCount) && ~any(tr.frontendBoundaryFlag));
    summary=struct('passed',true,'faultInjection','TrkCN0Th=80 dB-Hz; not a scientific comparison', ...
        'reacqMs',nnz(tr.trk_state==9),'successfulHandovers',numel(tokens), ...
        'columns',{{'epoch','logicalBefore','logicalAfter','rewindSamples'}},'handoverEvidence',evidence);
    writeJson(fullfile(outputRoot,'reacq_summary.json'),summary);
end

function writeJson(path,value)
    fid=fopen(path,'w','n','UTF-8'); assert(fid>=0); cl=onCleanup(@() fclose(fid));
    fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
