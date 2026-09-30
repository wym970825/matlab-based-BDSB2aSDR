function summary=compare_tf_validation(runDirs,outputRoot)
%COMPARE_TF_VALIDATION Physical-time matched native outputs, without resampling.
% Match native windows with >=99% overlap; also report a <=2-sample subset.
% Report actual edge mismatch. Inferential
% observations are >=60-second blocks, not overlapping 5-second S4 updates.
    setupPaths();
    if ischar(runDirs) || isstring(runDirs)
        parent=char(runDirs); runDirs=cellfun(@(m) fullfile(parent,m), ...
            {'pb','tf400','tf600'},'UniformOutput',false);
    end
    if nargin<2, outputRoot=fullfile(fileparts(runDirs{1}),'comparison'); end
    assert(~isfolder(outputRoot),'TFCompare:OutputExists','Use a fresh output folder.');
    mkdir(outputRoot); series=cell(size(runDirs)); stats=cell(size(runDirs));
    for k=1:numel(runDirs)
        rd=runDirs{k}; report=jsondecode(fileread(fullfile(rd,'report.json')));
        assert(report.ok,'TFCompare:FailedRun','Cannot compare failed run.');
        cfg=jsondecode(fileread(fullfile(rd,'validation_config.json')));
        loaded=load(fullfile(rd,['run_B2a_' report.tag '.mat']),'results');
        tr=trackResultsToStruct(loaded.results.trackResults); tr=tr([tr.PRN]==11);
        assert(numel(tr)==1);
        fs=cfg.samplingFreq; step=cfg.CNoInterval; count=numel(tr.I_P);
        ends=step:step:count; starts=ends-step+1;
        normal=tr.trk_state~=9 & tr.frontendValidCount==tr.frontendSampleCount & ...
            ~tr.frontendBoundaryFlag & tr.frontendSampleCount>0;
        stable=normal & tr.cur_state;
        valid=all(reshape(stable(1:ends(end)),step,[]),1);
        % The receiver saves (current + previous) C/N0 / 2 every 200 ms.
        % Its stored estimate therefore has two-window temporal support.
        valid=valid & [false valid(1:end-1)];
        startTime=tr.absoluteSample(max(1,starts-step))/fs;
        endTime=(tr.absoluteSample(ends)+tr.frontendSampleCount(ends))/fs;
        valid=valid & startTime>=150 & isfinite(tr.PilotCNo(1:numel(ends))) & tr.PilotCNo(1:numel(ends))>0;
        [~,label]=fileparts(rd);
        power=tr.Pilot_I_P.^2+tr.Pilot_Q_P.^2;
        steady=normal & tr.cur_state & tr.absoluteSample/fs>=150;
        p=power(steady);
        stats{k}=struct('mode',label,'outDir',rd,'recordedMs',count,'validSteadyCnoWindows',nnz(valid), ...
            'reacqMs',nnz(tr.trk_state==9),'meanWeight',mean(tr.frontendMeanWeight), ...
            'frontendBoundaryMs',nnz(tr.frontendBoundaryFlag), ...
            'dllDiscriminatorStdDimensionless',std(tr.dllDiscr(steady),0,'omitnan'), ...
            'pllDiscriminatorStdCycles',std(tr.pllDiscr(steady),0,'omitnan'), ...
            'promptPowerMean',mean(p),'promptPowerCV',std(p)/mean(p), ...
            'medianPilotCno',median(tr.PilotCNo(valid)), ...
            'medianTotalCno',median(tr.B2a_CNo(valid)), ...
            'finiteS4Updates',nnz(isfinite(tr.S4)), ...
            'medianS4',median(tr.S4,'omitnan'),'medianS4Raw',median(tr.S4_ori,'omitnan'));
        series{k}=struct('mode',label,'fs',fs,'startTime',startTime,'endTime',endTime, ...
            'key',round(endTime/(step/1000)),'valid',valid, ...
            'pilot',tr.PilotCNo(1:numel(ends)),'total',tr.B2a_CNo(1:numel(ends)), ...
            's4',tr.S4(1:numel(ends)),'s4Raw',tr.S4_ori(1:numel(ends)), ...
            'power',mean(reshape(power(1:ends(end)),step,[]),1));
        assert(numel(unique(series{k}.key))==numel(series{k}.key), ...
            'TFCompare:AmbiguousTime','Duplicate physical bins; split reacquisition segments before pairing.');
        clear loaded tr power
    end
    pairs={};
    for a=1:numel(series)-1
        for b=a+1:numel(series)
            x=series{a}; y=series{b};
            [~,ix,iy]=intersect(x.key,y.key);
            mismatch=max(abs(x.startTime(ix)-y.startTime(iy)),abs(x.endTime(ix)-y.endTime(iy)));
            overlap=max(0,min(x.endTime(ix),y.endTime(iy))-max(x.startTime(ix),y.startTime(iy)));
            duration=max(x.endTime(ix)-x.startTime(ix),y.endTime(iy)-y.startTime(iy));
            overlapFraction=overlap./duration;
            use=x.valid(ix)&y.valid(iy)&overlapFraction>=.99;
            ix=ix(use); iy=iy(use); mismatch=mismatch(use);
            overlapFraction=overlapFraction(use);
            time=max(x.endTime(ix),y.endTime(iy));
            diffPilot=y.pilot(iy)-x.pilot(ix); diffTotal=y.total(iy)-x.total(ix);
            q=struct('comparison',[y.mode ' minus ' x.mode], ...
                'commonCnoWindows',numel(ix),'matchedCoverageSec',numel(ix)*step/1000, ...
                'maxWindowEdgeMismatchUs',max(mismatch)*1e6, ...
                'minimumWindowOverlapFraction',min(overlapFraction), ...
                'meanPilotDifferenceDb',mean(diffPilot),'medianPilotDifferenceDb',median(diffPilot), ...
                'meanTotalDifferenceDb',mean(diffTotal));
            % Native S4 only; NaN indicates no update, never interpolate it.
            haveS4=isfinite(x.s4(ix))&isfinite(y.s4(iy));
            q.commonS4Updates=nnz(haveS4);
            q.meanS4Difference=mean(y.s4(iy(haveS4))-x.s4(ix(haveS4)));
            q.blocks60=blockStats(time,diffPilot,60);
            q.blocks120=blockStats(time,diffPilot,120);
            strict=mismatch<=2/min(x.fs,y.fs)+1e-12;
            q.strictToleranceSamples=2; q.strictCommonCnoWindows=nnz(strict);
            q.strictMeanPilotDifferenceDb=mean(diffPilot(strict));
            q.strictMeanTotalDifferenceDb=mean(diffTotal(strict));
            q.strictBlocks60=blockStats(time(strict),diffPilot(strict),60);
            q.strictBlocks120=blockStats(time(strict),diffPilot(strict),120);
            pairs{end+1}=q; %#ok<AGROW>
        end
    end
    summary=struct('warmupExclusionSeconds',150,'minimumNativeWindowOverlap',.99, ...
        'nativeUpdateIntervalMs',step,'storedCnoSupportMs',2*step, ...
        'analysisScriptHash',frontendHash(fileread([mfilename('fullpath') '.m'])), ...
        'pairing','Nearest physical 200-ms bin, >=99% overlap; separate <=2-sample subset; no interpolation.', ...
        'notes','Single file/PRN; overlapping S4 outputs are descriptive, not independent trials. No S4 truth.', ...
        'runs',{stats},'pairs',{pairs});
    fid=fopen(fullfile(outputRoot,'comparison.json'),'w','n','UTF-8'); cl=onCleanup(@() fclose(fid));
    fprintf(fid,'%s\n',jsonencode(summary,'PrettyPrint',true)); clear cl
    save(fullfile(outputRoot,'native_series.mat'),'series','summary');
    f=figure('Visible','off','Position',[100 100 1200 750]); cl=onCleanup(@() close(f));
    tiledlayout(2,2);
    for field={'pilot','s4','s4Raw','power'}
        nexttile; hold on;
        for k=1:numel(series)
            x=series{k}; value=x.(field{1}); value(~x.valid | ~isfinite(value))=NaN;
            plot(x.endTime,value,'.-','DisplayName',x.mode);
        end
        xlabel('Physical file time (s)'); title(field{1},'Interpreter','none');
        grid on; legend('Location','best','Interpreter','none');
    end
    exportgraphics(f,fullfile(outputRoot,'comparison.png'),'Resolution',150);
end

function result=blockStats(time,delta,seconds)
    % Fixed [150,150+seconds) bins; retain only complete coverage blocks.
    id=floor((time-150)/seconds); values=[]; endpoints=[];
    for b=unique(id)
        use=id==b;
        if nnz(use)<.98*seconds/.2, continue; end
        values(end+1)=mean(delta(use)); endpoints(end+1)=150+(b+1)*seconds; %#ok<AGROW>
    end
    result=struct('blockLengthSec',seconds,'nBlocks',numel(values), ...
        'blockEndSeconds',endpoints,'pilotMeanDifferencesDb',values, ...
        'meanDb',mean(values),'minimumBlockDb',min(values),'maximumBlockDb',max(values));
    % Descriptive block dispersion only: one recorded realization does not
    % establish independence or a general confidence interval.
    result.stdAcrossBlocksDb=std(values);
end
