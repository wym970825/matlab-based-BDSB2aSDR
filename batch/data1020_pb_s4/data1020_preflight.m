function data1020_preflight()
set(groot,'defaultFigureVisible','off');
[cases,out]=data1020_config();
mkdir(out); mkdir(fullfile(out,'preflight'));
diary(fullfile(out,'preflight','matlab_preflight.md'));
fprintf('# DATA1020 PB S4 preflight\n\nMATLAB %s\nRoot %s\n',version,matlabroot);
disp(ver('signal')); disp(ver('optim'));
disp(ver('stats'));
for name=["data1020_main","data1020_compute","data1020_navigation","data1020_plot","data1020_write_md"]
    fprintf('Parsed %s: nargin=%d\n',name,nargin(name));
end
checks=table();
for k=1:3
    c=cases{k}; cfg=c.cfg;
    [th,cal]=s4repair.power.receiverCalibration(c.settings,cfg);
    fprintf('\nExperiment %02d: Fs=%g; offset=%g Hz; threshold=%.9f dBm\n',c.entry.experimentNumber,c.settings.samplingFreq,cfg.deltaFrequencyHz,th);
    for prn=cfg.prns
        track=s4repair.io.loadTrackChunks(cfg.resultDir,prn,cfg);
        f=load(fullfile(cfg.resultDir,'temp',sprintf('Trk_Prn_%02d_final.mat',prn)));
        fields=fieldnames(f); final=f.(fields{1});
        sample=double(final.absoluteSample(:)); sample=sample(isfinite(sample) & sample>=0);
        same=isequal(track.absoluteSample,unique(sample,'sorted'));
        [utc,tm]=s4repair.time.mapSamplesToUtc(track.absoluteSample,c.anchors,c.settings.samplingFreq);
        w=s4repair.time.wholeMinuteWindows(utc,cfg.coherentIntegrationSec);
        stable=ismember(track.trk_state,[3 4]);
        finite=isfinite(track.Pilot_I_P) & isfinite(track.Pilot_Q_P) & ...
            isfinite(track.Ppre) & isfinite(track.Ppost) & isfinite(track.eta);
        complete=all(finite(stable));
        code=s4repair.power.generateB2aPilotCode(prn);
        ok=same && complete && numel(code)==10230 && height(w)>=2 && ...
            tm.maxAbsResidualSec<cfg.maxTimeAnchorResidualSec && all(diff(track.absoluteSample)>0) && ...
            all(track.eta(stable)>=0 & track.eta(stable)<1) && ~isempty(track.cnoDbHz);
        row=table(c.entry.experimentNumber,prn,numel(track.absoluteSample),same,complete,height(w), ...
            tm.maxAbsResidualSec,utc(1),utc(end),th,cal.frontEndResponseVerified,nnz(~finite),nnz(~finite & stable),ok, ...
            'VariableNames',{'Experiment','PRN','Samples','FinalMatchesChunks','FiniteStableInputs','UtcMinutes', ...
            'AnchorResidualSeconds','FirstTrackingUtc','LastTrackingUtc','ThresholdDbm','HardwareRuleResult','NonfiniteTicks','NonfiniteStableTicks','Passed'});
        checks=[checks;row]; %#ok<AGROW>
        fprintf('PRN %02d: samples=%d minutes=%d matchesFinal=%d passed=%d\n',prn,row.Samples,row.UtcMinutes,same,ok);
        clear f final track
    end
end
data1020_write_md(fullfile(out,'preflight','input_checks.md'),checks,'26组输入检查');
assert(all(checks.Passed),'Input check failed; see input_checks.md');
% Build each requested PRN/frequency block before the main run.
for k=1:2
    c=cases{k}; ps=c.cfg.prns;
    if k==2, ps=unique([ps cases{3}.cfg.prns]); end
    for prn=ps
        [lut,cache]=s4repair.power.ensureResidualSscLut(prn,"pilot",c.settings.samplingFreq,c.cfg);
        assert(all(isfinite(lut.SSC)) && lut.responseBandwidthHz>0);
        fprintf('SSC ready: %s\n',cache);
    end
end
save(fullfile(out,'preflight','input_complete.mat'),'cases','checks','-v7.3');
data1020_smoke();
diary off
end
