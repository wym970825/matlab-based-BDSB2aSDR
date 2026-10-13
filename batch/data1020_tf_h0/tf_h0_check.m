function tf_h0_check()
cd('F:/matlab-GNSSsdr/BDS/B2a');setupPaths;addpath('batch/data1020_pb_s4');
out="F:/matlab-GNSSsdr/BDS/B2a/results/data1020/20261010_tf_h0_20s";
load(fullfile(out,'prepared.mat'),'cases');rows=table();
for k=1:3
    c=cases{k};cfg=c.settings;cfg.msToProcess=5000;
    cfg.resultRoot='';cfg.outDir=char(fullfile(out,sprintf('check_%02d',c.entry.experimentNumber)));
    cfg.tempdataSvPth=fullfile(cfg.outDir,'temp');mkdir(cfg.tempdataSvPth);
    cfg.Frontend=struct('mode','tf_v1','TF',struct('centerHz',c.centerHz,'stopbandWidthHz',c.bandwidthHz, ...
        'thresholdAmplitude',c.threshold,'triangleSpanUs',3));
    cfg=resolveFrontendSettings(cfg);
    [path,~]=trackOneChannel(c.channel([c.channel.PRN]==38),cfg,1,1,true);
    s=load(path,'finalTRes');t=s.finalTRes;
    assert(numel(t.absoluteSample)==5000 && t.frontendInfo.TF.effectiveThresholdAmplitude==c.threshold);
    valid=double(t.B2a_CNo(:));valid=valid(isfinite(valid) & valid>0);
    r=table(c.entry.experimentNumber,numel(t.absoluteSample),nnz(ismember(t.trk_state,[3 4])), ...
        numel(valid),median(valid),mean(t.frontendDetectorDuty),mean(t.frontendMeanWeight), ...
        'VariableNames',{'Experiment','Samples','LongTicks','FiniteB2aCno','MedianB2aCno','DetectorDuty','MeanWeight'});
    rows=[rows;r]; %#ok<AGROW>
end
data1020_write_md(fullfile(out,'tracking_check.md'),rows,'三组PRN38五秒入口检查');
save(fullfile(out,'tracking_check.mat'),'rows');
end
