function summary=analyze_tf600_edges(runDirs,outputRoot)
%ANALYZE_TF600_EDGES Physical-time comparison with complete 60-s S4 screening.
% Pass 3/6/9-us runs then archived 12-us reference. No interpolation or retuning.
    setupPaths(); assert(numel(runDirs)==4 && ~isfolder(outputRoot));
    series=cell(1,4); runs=cell(1,4); expectedSpans=[3 6 9 12];
    for k=1:4
        rd=runDirs{k}; cfg=jsondecode(fileread(fullfile(rd,'validation_config.json')));
        report=jsondecode(fileread(fullfile(rd,'report.json'))); assert(report.ok);
        archive=load(fullfile(rd,['run_B2a_' report.tag '.mat']),'results');
        tr=trackResultsToStruct(archive.results.trackResults); tr=tr([tr.PRN]==11);
        assert(isscalar(tr) && cfg.longCoh_ms==1);
        resolved=resolveFrontendSettings(cfg); tf=resolved.Frontend.TF;
        assert(tf.stopbandWidthHz==600e3 && tf.triangleSpanUs==expectedSpans(k), ...
            'Expected ordered 3/6/9/12-us runs with fixed 600-kHz bandwidth.');
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
        [~,label]=fileparts(rd);
        series{k}=struct('label',label,'spanUs',tf.triangleSpanUs,'fs',fs,'key',key, ...
            'startTime',startTime,'endTime',endTime,'valid',valid,'pilot',pilot,'total',total, ...
            's4',s4,'s4Raw',raw,'s4FullLong',fullLong,'s4StartTime',s4StartTime);
        long=logical(tr.cur_state); first=[1 find(diff(long)~=0)+1]; last=[first(2:end)-1 n];
        intervals=arrayfun(@(a,b) struct('long',long(a),'firstEpoch',a,'lastEpoch',b, ...
            'durationMs',b-a+1,'startTimeSec',tr.absoluteSample(a)/fs, ...
            'endTimeSec',(tr.absoluteSample(b)+tr.frontendSampleCount(b))/fs),first,last);
        counts=tr.frontendSampleCount(normal); totalSamples=sum(counts);
        steady=stable & tr.absoluteSample/fs>=150; power=tr.Pilot_I_P.^2+tr.Pilot_Q_P.^2;
        runs{k}=struct('label',label,'nominalOuterSpanUs',tf.triangleSpanUs, ...
            'actualOuterSpanUs',tf.actualTriangleSpanUs,'D',tf.D,'K',tf.K,'P',tf.P,'A',tf.A,'H',tf.H, ...
            'recordedMs',n,'reacqMs',nnz(tr.trk_state==9),'longMs',nnz(long), ...
            'frontendInvalidMs',nnz(~normal & tr.trk_state~=9), ...
            'meanDetectorDutyBySample',sum(tr.frontendDetectorDuty(normal).*counts)/totalSamples, ...
            'meanWeightBySample',sum(tr.frontendMeanWeight(normal).*counts)/totalSamples, ...
            'meanWeightSquaredBySample',sum(tr.frontendMeanWeightSquared(normal).*counts)/totalSamples, ...
            'weightSupportFractionBySample',sum(tr.frontendWeightSupportFraction(normal).*counts)/totalSamples, ...
            'validCnoUpdates',nnz(valid),'ambiguousPhysicalBinsExcluded',nnz(~uniqueBin), ...
            'finiteS4Updates',nnz(isfinite(s4)),'finiteS4WithoutFullLongWindow',nnz(isfinite(s4)&~fullLong), ...
            'affectedS4TimesSec',endTime(isfinite(s4)&~fullLong), ...
            'medianSteadyPilotCno',median(pilot(valid)),'medianSteadyTotalCno',median(total(valid)), ...
            'medianS4FullLong',median(s4(fullLong),'omitnan'), ...
            'dllDiscriminatorStd',std(tr.dllDiscr(steady),0,'omitnan'), ...
            'pllDiscriminatorStdCycles',std(tr.pllDiscr(steady),0,'omitnan'), ...
            'promptPowerMean',mean(power(steady)),'promptPowerCV',std(power(steady))/mean(power(steady)), ...
            'longIntervals',intervals,'nhAudit',nhAudit(tr,cfg));
        clear archive tr power
    end
    pairs={}; differences={};
    for a=1:3
        for b=a+1:4
            x=series{a}; y=series{b}; [~,ix,iy]=intersect(x.key,y.key);
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
            label=sprintf('%g us minus %g us',x.spanUs,y.spanUs);
            pairs{end+1}=struct('comparison',label,'commonCnoUpdates',nnz(use), ...
                'matchedUpdateCoverageSeconds',nnz(use)*.2,'maximumCnoEdgeMismatchUs',max(mismatch(use))*1e6, ...
                'meanPilotDifferenceDb',mean(d(use)),'medianPilotDifferenceDb',median(d(use)), ...
                'meanTotalDifferenceDb',mean(dt(use)),'strictCommonCnoUpdates',nnz(strict), ...
                'strictMeanPilotDifferenceDb',mean(d(strict)), ...
                'blocks60',blocks(time(use),d(use),60),'blocks120',blocks(time(use),d(use),120), ...
                'commonS4Full60sLong',nnz(s4Use),'meanS4Difference',mean(ds(s4Use)), ...
                'rmsS4Difference',sqrt(mean(ds(s4Use).^2)),'maxAbsoluteS4Difference',max(abs(ds(s4Use))), ...
                'meanRawS4Difference',mean(dr(s4Use))); %#ok<AGROW>
            d(~use)=NaN; ds(~s4Use)=NaN; dr(~s4Use)=NaN;
            differences{end+1}=struct('label',label,'time',time,'pilot',d,'s4',ds,'rawS4',dr); %#ok<AGROW>
        end
    end
    % A shared four-way mask avoids ranking means from different state windows.
    common=series{1}.key(series{1}.valid);
    for k=2:4, common=intersect(common,series{k}.key(series{k}.valid)); end
    indices=zeros(4,numel(common)); start=zeros(size(indices)); finish=start; s4begin=start;
    cno=start; total=start; s4=start; raw=start; s4mask=true(size(indices));
    for k=1:4
        x=series{k}; [ok,index]=ismember(common,x.key); assert(all(ok)); indices(k,:)=index;
        start(k,:)=x.startTime(index); finish(k,:)=x.endTime(index); s4begin(k,:)=x.s4StartTime(index);
        cno(k,:)=x.pilot(index); total(k,:)=x.total(index); s4(k,:)=x.s4(index); raw(k,:)=x.s4Raw(index);
        s4mask(k,:)=x.s4FullLong(index)&isfinite(x.s4(index));
    end
    good=(min(finish,[],1)-max(start,[],1))./max(finish-start,[],1)>=.99;
    goodS4=good & all(s4mask,1) & (min(finish,[],1)-max(s4begin,[],1))./max(finish-s4begin,[],1)>=.99;
    commonRows=cell(1,4);
    for k=1:4
        ds=s4(k,goodS4)-s4(4,goodS4);
        commonRows{k}=struct('spanUs',series{k}.spanUs,'meanPilotCno',mean(cno(k,good)), ...
            'meanTotalCno',mean(total(k,good)), ...
            'meanPilotDifferenceVs12Db',mean(cno(k,good)-cno(4,good)), ...
            'meanS4DifferenceVs12',mean(ds),'rmsS4DifferenceVs12',sqrt(mean(ds.^2)), ...
            'meanRawS4DifferenceVs12',mean(raw(k,goodS4)-raw(4,goodS4)));
    end
    summary=struct('bandwidthHz',600e3,'warmupSeconds',150,'minimumOverlap',.99, ...
        's4WindowRequirement','All 60000 native epochs valid LONG; IIR memory is not finite.', ...
        'notes','One file and PRN. Paired estimates are not truth errors. Overlapping outputs are not independent trials.', ...
        'runs',{runs},'pairs',{pairs},'fourWayCommonCnoUpdates',nnz(good), ...
        'fourWayCommonS4Updates',nnz(goodS4),'fourWayRows',{commonRows}, ...
        'scriptHash',frontendHash(fileread([mfilename('fullpath') '.m'])));
    mkdir(outputRoot); fid=fopen(fullfile(outputRoot,'edge_analysis.json'),'w','n','UTF-8'); assert(fid>=0);
    cleaner=onCleanup(@() fclose(fid)); fprintf(fid,'%s\n',jsonencode(summary,'PrettyPrint',true)); clear cleaner
    save(fullfile(outputRoot,'edge_series.mat'),'series','summary','differences','common','indices','good','goodS4');
    f=figure('Visible','off','Position',[100 100 1150 950]); cleaner=onCleanup(@() close(f));
    tiledlayout(3,1);
    for panel=1:3
        nexttile; hold on;
        for j=[3 5 6] % each new span minus the archived 12-us reference
            d=differences{j}; fields={'pilot','s4','rawS4'};
            plot(d.time,d.(fields{panel}),'.-','DisplayName',d.label);
        end
        yline(0,':','HandleVisibility','off'); grid on; legend('Location','best');
        labels={'Pilot C/N0 difference (dB)','Corrected S4 difference','Raw S4 difference'};
        ylabel(labels{panel}); xlabel('Physical file time (s)');
    end
    exportgraphics(f,fullfile(outputRoot,'edge_differences.png'),'Resolution',150);
    clear cleaner
    f=figure('Visible','off','Position',[100 100 1100 800]); cleaner=onCleanup(@() close(f));
    tiledlayout(2,2); spans=cellfun(@(x) x.spanUs,series);
    nexttile; plot(spans,100*cellfun(@(x) x.meanWeightBySample,runs),'o-');
    xlabel('Nominal outer transition (us)'); ylabel('Mean notch weight (%)'); grid on;
    nexttile; plot(spans,cellfun(@(x) x.meanPilotDifferenceVs12Db,commonRows),'o-');
    yline(0,':'); xlabel('Nominal outer transition (us)'); ylabel('Pilot C/N0 minus 12 us (dB)');
    title(sprintf('%d common native C/N0 updates',nnz(good))); grid on;
    confidence=nan(1,4);
    for k=1:4
        nh=runs{k}.nhAudit;
        if strcmp(nh.status,'all_decisions_verified')
            use=cellfun(@(e) e.epoch>=150000,nh.events);
            confidence(k)=min(cellfun(@(e) e.confidence,nh.events(use)));
        end
    end
    nexttile; plot(spans,confidence,'o-'); yline(cfg.weilConfTh,'--','Threshold');
    xlabel('Nominal outer transition (us)'); ylabel('Minimum reconstructed Weil peak ratio');
    title('Estimates after 150 s; no-REACQ runs'); grid on;
    nexttile; plot(spans,cellfun(@(x) x.rmsS4DifferenceVs12,commonRows),'o-');
    xlabel('Nominal outer transition (us)'); ylabel('S4 RMS difference versus 12 us');
    title(sprintf('%d common full-LONG 60-s windows; no truth',nnz(goodS4))); grid on;
    exportgraphics(f,fullfile(outputRoot,'edge_overview.png'),'Resolution',150);
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
