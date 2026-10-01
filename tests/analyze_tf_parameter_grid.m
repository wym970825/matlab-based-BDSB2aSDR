function summary=analyze_tf_parameter_grid(gridRoot,outputRoot)
%ANALYZE_TF_PARAMETER_GRID Compare all 12 actual-IF bandwidth/edge runs.
% Physical-time native updates; full 60-s LONG S4 support; no interpolation.
    root=setupPaths(); assert(~isfolder(outputRoot));
    runDirs=cell(1,12); expectedBands=repelem([400e3 600e3 800e3],4);
    expectedSpans=repmat([3 6 9 12],1,3);
    for k=1:12
        bw=expectedBands(k); span=expectedSpans(k);
        if span==12
            if bw==800e3
                rd=fullfile(root,'results','tf600_vs_tf800','run_03','full','tf800');
            else
                rd=fullfile(root,'results','upgrade_v020','full_01',sprintf('tf%g',bw/1e3));
            end
        elseif bw==600e3
            rd=fullfile(root,'results','tf600_soft_edges','run_01','full',sprintf('edge%gus',span));
        else
            rd=fullfile(gridRoot,'full',sprintf('tf%g_edge%gus',bw/1e3,span));
        end
        runDirs{k}=rd;
    end
    base=jsondecode(fileread(fullfile(runDirs{8},'validation_config.json')));
    series=cell(1,12); runs=cell(1,12);
    for k=1:12
        rd=runDirs{k}; cfg=jsondecode(fileread(fullfile(rd,'validation_config.json')));
        normalized=cfg; normalized.tag=base.tag;
        normalized.Frontend.TF.stopbandWidthHz=base.Frontend.TF.stopbandWidthHz;
        if isfield(normalized.Frontend.TF,'triangleSpanUs')
            normalized.Frontend.TF=rmfield(normalized.Frontend.TF,'triangleSpanUs');
        end
        assert(isequaln(normalized,base),'Unexpected non-frontend configuration change.');
        runSummary=jsondecode(fileread(fullfile(rd,'validation_summary.json')));
        assert(runSummary.complete && runSummary.recordedMs==715000);
        report=jsondecode(fileread(fullfile(rd,'report.json'))); assert(report.ok);
        archive=load(fullfile(rd,['run_B2a_' report.tag '.mat']),'results');
        tr=trackResultsToStruct(archive.results.trackResults); tr=tr([tr.PRN]==11);
        assert(isscalar(tr) && cfg.longCoh_ms==1);
        resolved=resolveFrontendSettings(cfg); tf=resolved.Frontend.TF;
        assert(tf.stopbandWidthHz==expectedBands(k) && tf.triangleSpanUs==expectedSpans(k), ...
            'Unexpected grid order or resolved parameters.');
        fs=cfg.samplingFreq; n=numel(tr.I_P); step=cfg.CNoInterval;
        ends=step:step:n; starts=max(1,ends-2*step+1);
        normal=tr.trk_state~=9 & tr.frontendValidCount==tr.frontendSampleCount & ...
            tr.frontendSampleCount>0 & ~tr.frontendBoundaryFlag;
        stable=normal & tr.cur_state; bad=[0 cumsum(~stable)];
        valid=bad(ends+1)-bad(starts)==0;
        startTime=tr.absoluteSample(starts)/fs;
        endTime=(tr.absoluteSample(ends)+tr.frontendSampleCount(ends))/fs;
        pilot=tr.PilotCNo(1:numel(ends)); total=tr.B2a_CNo(1:numel(ends));
        valid=valid & startTime>=150 & isfinite(pilot) & pilot>0 & isfinite(total) & total>0;
        s4Start=ends-cfg.scint_bufLen+1; eligible=s4Start>=1;
        fullLong=false(size(ends)); fullLong(eligible)=bad(ends(eligible)+1)-bad(s4Start(eligible))==0;
        s4StartTime=nan(size(ends)); s4StartTime(eligible)=tr.absoluteSample(s4Start(eligible))/fs;
        key=round(endTime/(step/1000));
        [~,~,group]=unique(key); counts=accumarray(group(:),1); uniqueBin=reshape(counts(group)==1,size(key));
        valid=valid & uniqueBin; % Never silently select one of two physical-bin matches.
        s4=tr.S4(1:numel(ends)); raw=tr.S4_ori(1:numel(ends));
        label=sprintf('%gk_%gus',tf.stopbandWidthHz/1e3,tf.triangleSpanUs);
        series{k}=struct('label',label,'bandwidthHz',tf.stopbandWidthHz,'spanUs',tf.triangleSpanUs,'fs',fs,'key',key, ...
            'startTime',startTime,'endTime',endTime,'valid',valid,'pilot',pilot,'total',total, ...
            's4',s4,'s4Raw',raw,'s4FullLong',fullLong,'s4StartTime',s4StartTime);
        long=logical(tr.cur_state); first=[1 find(diff(long)~=0)+1]; last=[first(2:end)-1 n];
        intervals=arrayfun(@(a,b) struct('long',long(a),'firstEpoch',a,'lastEpoch',b, ...
            'durationMs',b-a+1,'startTimeSec',tr.absoluteSample(a)/fs, ...
            'endTimeSec',(tr.absoluteSample(b)+tr.frontendSampleCount(b))/fs),first,last);
        counts=tr.frontendSampleCount(normal); totalSamples=sum(counts);
        steady=stable & tr.absoluteSample/fs>=150; power=tr.Pilot_I_P.^2+tr.Pilot_Q_P.^2;
        runs{k}=struct('label',label,'runDir',rd,'bandwidthHz',tf.stopbandWidthHz,'nominalOuterSpanUs',tf.triangleSpanUs, ...
            'actualOuterSpanUs',tf.actualTriangleSpanUs,'D',tf.D,'K',tf.K,'P',tf.P,'A',tf.A,'H',tf.H, ...
            'recordedMs',n,'reacqMs',nnz(tr.trk_state==9),'longMs',nnz(long), ...
            'frontendInvalidMs',nnz(~normal & tr.trk_state~=9), ...
            'postInitialNonLongMs',nnz(~long(cfg.trackInit_MS+1:end)), ...
            'complete',runSummary.complete,'maxNormalTimelineErrorSamples',runSummary.maxNormalTimelineErrorSamples, ...
            'elapsedSec',runSummary.elapsedSec,'firstSample',tr.absoluteSample(1),'lastSample',tr.absoluteSample(end), ...
            'meanDetectorDutyBySample',sum(tr.frontendDetectorDuty(normal).*counts)/totalSamples, ...
            'meanWeightBySample',sum(tr.frontendMeanWeight(normal).*counts)/totalSamples, ...
            'meanWeightSquaredBySample',sum(tr.frontendMeanWeightSquared(normal).*counts)/totalSamples, ...
            'weightSupportFractionBySample',sum(tr.frontendWeightSupportFraction(normal).*counts)/totalSamples, ...
            'validCnoUpdates',nnz(valid),'ambiguousPhysicalBinsExcluded',nnz(~uniqueBin), ...
            'finiteS4Updates',nnz(isfinite(s4)),'eligibleS4FullLongUpdates',nnz(valid & fullLong & isfinite(s4)),'finiteS4WithoutFullLongWindow',nnz(isfinite(s4)&~fullLong), ...
            'affectedS4TimesSec',endTime(isfinite(s4)&~fullLong), ...
            'medianSteadyPilotCno',median(pilot(valid)),'medianSteadyTotalCno',median(total(valid)), ...
            'medianS4FullLong',median(s4(fullLong),'omitnan'), ...
            'dllDiscriminatorStd',std(tr.dllDiscr(steady),0,'omitnan'), ...
            'pllDiscriminatorStdCycles',std(tr.pllDiscr(steady),0,'omitnan'), ...
            'promptPowerMean',mean(power(steady)),'promptPowerCV',std(power(steady))/mean(power(steady)), ...
            'longIntervals',intervals,'nhAudit',nhAudit(tr,cfg),'reacqAudit',reacqAudit(tr,archive.results.settings));
        clear archive tr power
    end
    pairs={}; differences={}; reference=7; % 600 kHz / 9 us, a reference, not truth.
    for a=1:11
        for b=a+1:12
            [pairs{end+1},differences{end+1}]=pairStats(series{a},series{b}); %#ok<AGROW>
        end
    end
    groups={sharedStats(series,1:12,reference,'all_12')};
    for band=1:3
        ix=(band-1)*4+(1:4);
        groups{end+1}=sharedStats(series,ix,ix(4),sprintf('%gk_all_edges',expectedBands(ix(1))/1e3)); %#ok<AGROW>
    end
    for edge=1:4
        ix=edge:4:12;
        groups{end+1}=sharedStats(series,ix,ix(2),sprintf('%gus_all_bandwidths',expectedSpans(edge))); %#ok<AGROW>
    end
    uninterrupted=find(cellfun(@(r) r.postInitialNonLongMs==0,runs));
    assert(ismember(reference,uninterrupted));
    groups{end+1}=sharedStats(series,uninterrupted,reference,'uninterrupted_after_initial_3s');
    referencePairs=cell(1,12);
    for k=1:12, referencePairs{k}=pairStats(series{k},series{reference}); end
    summary=struct('bandwidthsHz',[400e3 600e3 800e3],'outerSpansUs',[3 6 9 12], ...
        'referenceLabel',series{reference}.label,'warmupSeconds',150,'minimumOverlap',.99, ...
        's4WindowRequirement','All 60000 native epochs valid LONG; IIR memory is not finite.', ...
        'notes','One file and PRN; differences are not truth errors; overlapping outputs are not independent trials. Availability is reported separately from common-window values.', ...
        'runs',{runs},'pairs',{pairs},'groups',{groups},'referencePairs',{referencePairs}, ...
        'scriptHash',frontendHash(fileread([mfilename('fullpath') '.m'])));
    mkdir(outputRoot); summary.filterResponses=drawResponse(base,outputRoot);
    writeJson(fullfile(outputRoot,'grid_analysis.json'),summary);
    save(fullfile(outputRoot,'grid_series.mat'),'series','summary','differences');
    drawOverview(summary,outputRoot);
    drawSeries(series,outputRoot);
end

function [result,difference]=pairStats(x,y)
    [~,ix,iy]=intersect(x.key,y.key);
    overlap=min(x.endTime(ix),y.endTime(iy))-max(x.startTime(ix),y.startTime(iy));
    duration=max(x.endTime(ix)-x.startTime(ix),y.endTime(iy)-y.startTime(iy));
    mismatch=max(abs(x.startTime(ix)-y.startTime(iy)),abs(x.endTime(ix)-y.endTime(iy)));
    use=x.valid(ix)&y.valid(iy)&overlap./duration>=.99;
    strict=use & mismatch<=2/min(x.fs,y.fs)+1e-12;
    d=x.pilot(ix)-y.pilot(iy); dt=x.total(ix)-y.total(iy);
    time=max(x.endTime(ix),y.endTime(iy));
    s4Overlap=min(x.endTime(ix),y.endTime(iy))-max(x.s4StartTime(ix),y.s4StartTime(iy));
    s4Duration=max(x.endTime(ix)-x.s4StartTime(ix),y.endTime(iy)-y.s4StartTime(iy));
    s4Use=use & x.s4FullLong(ix)&y.s4FullLong(iy)&isfinite(x.s4(ix))&isfinite(y.s4(iy)) & ...
        s4Overlap./s4Duration>=.99;
    ds=x.s4(ix)-y.s4(iy); dr=x.s4Raw(ix)-y.s4Raw(iy);
    label=[x.label ' minus ' y.label];
    result=struct('comparison',label,'commonCnoUpdates',nnz(use), ...
        'matchedUpdateCoverageSeconds',nnz(use)*.2,'maximumCnoEdgeMismatchUs',max(mismatch(use))*1e6, ...
        'meanPilotDifferenceDb',mean(d(use)),'medianPilotDifferenceDb',median(d(use)), ...
        'meanTotalDifferenceDb',mean(dt(use)),'strictCommonCnoUpdates',nnz(strict), ...
        'strictMeanPilotDifferenceDb',mean(d(strict)), ...
        'blocks60',blocks(time(use),d(use),60),'blocks120',blocks(time(use),d(use),120), ...
        'commonS4Full60sLong',nnz(s4Use),'meanS4Difference',mean(ds(s4Use)), ...
        'rmsS4Difference',sqrt(mean(ds(s4Use).^2)),'maxAbsoluteS4Difference',max(abs(ds(s4Use))), ...
        'meanRawS4Difference',mean(dr(s4Use)));
    d(~use)=NaN; ds(~s4Use)=NaN; dr(~s4Use)=NaN;
    difference=struct('label',label,'time',time,'pilot',d,'s4',ds,'rawS4',dr);
end

function group=sharedStats(series,members,reference,label)
    assert(ismember(reference,members));
    common=series{members(1)}.key(series{members(1)}.valid);
    for k=members(2:end), common=intersect(common,series{k}.key(series{k}.valid)); end
    dimensions=[numel(members) numel(common)];
    start=zeros(dimensions); finish=start; s4begin=start;
    cno=start; total=start; s4=start; raw=start; s4mask=true(dimensions);
    for j=1:numel(members)
        x=series{members(j)}; [ok,index]=ismember(common,x.key); assert(all(ok));
        start(j,:)=x.startTime(index); finish(j,:)=x.endTime(index); s4begin(j,:)=x.s4StartTime(index);
        cno(j,:)=x.pilot(index); total(j,:)=x.total(index); s4(j,:)=x.s4(index); raw(j,:)=x.s4Raw(index);
        s4mask(j,:)=x.s4FullLong(index)&isfinite(x.s4(index));
    end
    good=(min(finish,[],1)-max(start,[],1))./max(finish-start,[],1)>=.99;
    goodS4=good & all(s4mask,1) & (min(finish,[],1)-max(s4begin,[],1))./max(finish-s4begin,[],1)>=.99;
    strict=good & max(max(start,[],1)-min(start,[],1),max(finish,[],1)-min(finish,[],1)) ...
        <=2/min(cellfun(@(s) s.fs,series(members)))+1e-12;
    rows=cell(1,numel(members)); ref=find(members==reference);
    for j=1:numel(members)
        x=series{members(j)}; ds=s4(j,goodS4)-s4(ref,goodS4);
        rows{j}=struct('label',x.label,'bandwidthHz',x.bandwidthHz,'spanUs',x.spanUs, ...
            'meanPilotCno',mean(cno(j,good)),'meanTotalCno',mean(total(j,good)), ...
            'meanPilotDifferenceVsReferenceDb',mean(cno(j,good)-cno(ref,good)), ...
            'strictMeanPilotDifferenceVsReferenceDb',mean(cno(j,strict)-cno(ref,strict)), ...
            'meanS4DifferenceVsReference',mean(ds),'rmsS4DifferenceVsReference',sqrt(mean(ds.^2)), ...
            'meanRawS4DifferenceVsReference',mean(raw(j,goodS4)-raw(ref,goodS4)));
    end
    group=struct('label',label,'memberIndices',members,'referenceLabel',series{reference}.label, ...
        'commonCnoUpdates',nnz(good),'commonS4Updates',nnz(goodS4),'strictCommonCnoUpdates',nnz(strict), ...
        'rows',{rows});
end

function audit=reacqAudit(tr,s)
    reacq=tr.trk_state==9; first=find(diff([false reacq])==1); last=find(diff([reacq false])==-1);
    events=cell(size(first));
    for j=1:numel(first)
        a=first(j); b=last(j); w=max(1,a-s.pllSaturationHoldMs):a-1;
        near=abs(tr.pllDiscrFilt(w))>=s.pllSaturationNcoRatio*s.pllMaxNcoHz;
        before=tr.absoluteSample(b)+tr.frontendSampleCount(b); after=NaN; rewind=NaN;
        if b<numel(reacq)
            after=tr.absoluteSample(b+1); rewind=before-after;
            assert(rewind>=1 && rewind<=round(s.samplingFreq*.001),'Unexpected REACQ handover.');
        end
        lastCno=floor((a-1)/s.CNoInterval); bins=max(1,lastCno-2):lastCno;
        events{j}=struct('firstEpoch',a,'lastEpoch',b,'durationMs',b-a+1, ...
            'physicalStartSeconds',tr.absoluteSample(a)/s.samplingFreq, ...
            'nearLimitOccupancy',mean(near),'guardOccupancyThreshold',s.pllSaturationRatio, ...
            'consistentWithPllSaturationGuard',mean(near)>=s.pllSaturationRatio, ...
            'precedingStoredTotalCno',tr.B2a_CNo(bins),'logicalBefore',before, ...
            'logicalResume',after,'rewindSamples',rewind);
    end
    audit=struct('eventCount',numel(first),'events',{events});
end

function drawOverview(summary,outputRoot)
    f=figure('Visible','off','Position',[100 100 1280 1000]); cleaner=onCleanup(@() close(f));
    tiledlayout(3,2,'TileSpacing','compact'); common=summary.groups{1}.rows; spans=[3 6 9 12];
    values={cellfun(@(x) x.meanPilotDifferenceVsReferenceDb,common), ...
        cellfun(@(x) x.longMs/1000,summary.runs), ...
        cellfun(@(x) x.eligibleS4FullLongUpdates,summary.runs), ...
        cellfun(@(x) x.rmsS4DifferenceVsReference,common), ...
        100*cellfun(@(x) x.meanWeightBySample,summary.runs), ...
        cellfun(@minNh,summary.runs)};
    labels={'Pilot C/N0 minus 600k / 9us (dB)','LONG duration (s)', ...
        'Eligible full-60s LONG S4 updates','S4 RMS difference vs 600k / 9us', ...
        'Mean notch weight (%)','Minimum Weil peak ratio after 150s'};
    for panel=1:6
        nexttile; hold on;
        for b=1:3
            ix=(b-1)*4+(1:4); plot(spans,values{panel}(ix),'o-','DisplayName',sprintf('%g kHz',summary.bandwidthsHz(b)/1e3));
        end
        if panel==6, yline(1.5,'--','Threshold','HandleVisibility','off'); end
        xlabel('Nominal outer transition (us)'); ylabel(labels{panel}); xticks(spans); grid on;
        legend('Location','best');
        ax=gca; ax.YAxis.Exponent=0;
        if panel==4, ytickformat('%.3f'); end
        if panel==1, title(sprintf('All 12: %d common native updates',summary.groups{1}.commonCnoUpdates)); end
        if panel==4, title(sprintf('All 12: %d common native S4 updates',summary.groups{1}.commonS4Updates)); end
        if panel==6, title('REACQ runs excluded from NH reconstruction'); end
    end
    exportgraphics(f,fullfile(outputRoot,'grid_overview.png'),'Resolution',150);
end

function value=minNh(run)
    value=NaN;
    if ~strcmp(run.nhAudit.status,'all_decisions_verified'), return; end
    events=run.nhAudit.events; use=cellfun(@(e) e.epoch>=150000,events);
    value=min(cellfun(@(e) e.confidence,events(use)));
end

function drawSeries(series,outputRoot)
    f=figure('Visible','off','Position',[100 100 1300 1100]); cleaner=onCleanup(@() close(f));
    tiledlayout(3,2,'TileSpacing','compact');
    for b=1:3
        for panel=1:2
            nexttile; hold on;
            for k=(b-1)*4+(1:4)
                x=series{k};
                if panel==1, y=x.pilot; keep=x.valid;
                else, y=x.s4; keep=x.valid & x.s4FullLong & isfinite(y); end
                y(~keep)=NaN; plot(x.endTime,y,'.-','DisplayName',sprintf('%g us',x.spanUs));
            end
            title(sprintf('%g kHz',x.bandwidthHz/1e3)); xlim([150 715]); grid on;
            xlabel('Physical file time (s)'); legend('Location','best');
            if panel==1, ylabel('Pilot C/N0 (dB-Hz)'); else, ylabel('Corrected S4; full 60-s LONG support'); end
        end
    end
    exportgraphics(f,fullfile(outputRoot,'grid_native_series.png'),'Resolution',150);
end

function writeJson(path,value)
    fid=fopen(path,'w','n','UTF-8'); assert(fid>=0); cleanup=onCleanup(@() fclose(fid));
    fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end

function rows=drawResponse(base,outputRoot)
    f=figure('Visible','off','Position',[100 100 1150 800]); cleaner=onCleanup(@() close(f));
    tiledlayout(2,1); frequency=linspace(-1.2e6,.4e6,16001); rows={};
    for fs=[25e6 30.69e6]
        nexttile; hold on;
        for bandwidth=[400e3 600e3 800e3]
            cfg=base; cfg.samplingFreq=fs; cfg.Frontend.TF.stopbandWidthHz=bandwidth;
            tf=TFBlankerV1(cfg); response=freqz(tf.Notch,1,2*pi*frequency/fs);
            gain0=20*log10(abs(sum(tf.Notch)));
            rows{end+1}=struct('samplingFreq',fs,'bandwidthHz',bandwidth, ...
                'taps',tf.Config.effectiveTaps,'coefficientHash',tf.Info.coefficientHash, ...
                'worstStopbandDbOn4001PointGrid',tf.Info.worstStopbandDbOnGrid, ...
                'branchMagnitudeAtDigitalZeroDb',gain0); %#ok<AGROW>
            plot(frequency/1e3,20*log10(max(abs(response),1e-7)), ...
                'DisplayName',sprintf('%g kHz',bandwidth/1e3));
        end
        xline(0,':','Digital 0 Hz','HandleVisibility','off'); grid on;
        ylim([-100 2]); xlim([-1200 400]); legend('Location','best');
        title(sprintf('Center -450 kHz; fs=%.2f MHz; %d taps',fs/1e6,tf.Config.effectiveTaps));
        xlabel('Digital IQ frequency (kHz)'); ylabel('FIR branch magnitude (dB)');
    end
    exportgraphics(f,fullfile(outputRoot,'grid_filter_response.png'),'Resolution',150);
end

function result=blocks(time,value,seconds)
    id=floor((time-150)/seconds); values=[]; ends=[];
    for b=unique(id)
        mask=id==b; if nnz(mask)<.98*seconds/.2, continue; end
        values(end+1)=mean(value(mask)); ends(end+1)=150+(b+1)*seconds; %#ok<AGROW>
    end
    result=struct('lengthSeconds',seconds,'nBlocks',numel(values),'endTimesSec',ends, ...
        'meanDifferencesDb',values,'meanDb',mean(values),'minDb',min(values),'maxDb',max(values));
end

function audit=nhAudit(tr,cfg)
    if any(tr.trk_state==9)
        audit=struct('status','not_reconstructed','reason','REACQ requires handover-specific phase anchors.'); return;
    end
    target=GenWeil(11); target=repmat(target(:),ceil((cfg.weilEstBuffLen+100)/100),1);
    phase=-1; anchor=-1; epoch=cfg.trackInit_MS; events={};
    while epoch<numel(tr.I_P)
        ix=epoch-cfg.weilEstBuffLen+1:epoch;
        p=(tr.Pilot_I_P(ix)+1i*tr.Pilot_Q_P(ix))*exp(-1i*pi/2);
        if any(tr.cur_state(ix))
            assert(all(tr.cur_state(ix)) && phase>=0);
            nh=target(mod(phase+ix-anchor,100)+1); p=p.*reshape(nh,size(p));
        end
        magnitude=zeros(100,1);
        for shift=0:99, magnitude(shift+1)=abs(sum(p(:).*conj(target(shift+1:shift+numel(ix))))); end
        [peak,best]=max(magnitude); magnitude(best)=-inf; confidence=peak/(max(magnitude)+eps);
        success=confidence>=cfg.weilConfTh;
        assert(success==logical(tr.cur_state(epoch+1)),'NH reconstruction does not match recorded state.');
        events{end+1}=struct('epoch',epoch,'confidence',confidence,'threshold',cfg.weilConfTh,'success',success); %#ok<AGROW>
        if success
            phase=best-1; anchor=ix(1); epoch=epoch+cfg.reEstimateMS;
        else
            phase=-1; anchor=-1; epoch=epoch+cfg.trackInit_MS;
        end
    end
    audit=struct('status','all_decisions_verified','count',numel(events),'events',{events});
end
