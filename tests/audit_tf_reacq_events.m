function audit=audit_tf_reacq_events(runRoot,outputRoot)
%AUDIT_TF_REACQ_EVENTS Diagnose real events from archived data, no loop tuning.
    setupPaths();
    if nargin<2, outputRoot=fullfile(runRoot,'reacq_audit'); end
    assert(~isfolder(outputRoot),'ReacqAudit:OutputExists','Use a fresh output folder.');
    mkdir(outputRoot); modes={'pb','tf400','tf600'}; records=cell(1,3);
    f=figure('Visible','off','Position',[100 100 1200 800]); cl=onCleanup(@() close(f));
    tiledlayout(3,1); ax1=nexttile; hold on; ax2=nexttile; hold on; ax3=nexttile; hold on;
    for k=1:3
        rd=fullfile(runRoot,modes{k}); report=jsondecode(fileread(fullfile(rd,'report.json')));
        assert(report.ok);
        loaded=load(fullfile(rd,['run_B2a_' report.tag '.mat']),'results');
        s=loaded.results.settings; tr=trackResultsToStruct(loaded.results.trackResults);
        tr=tr([tr.PRN]==11); assert(isscalar(tr));
        reacq=tr.trk_state==9;
        first=find(diff([false reacq])==1); last=find(diff([reacq false])==-1);
        events=cell(size(first));
        for j=1:numel(first)
            a=first(j); b=last(j); w=max(1,a-s.pllSaturationHoldMs):a-1;
            near=abs(tr.pllDiscrFilt(w))>=s.pllSaturationNcoRatio*s.pllMaxNcoHz;
            before=tr.absoluteSample(b)+tr.frontendSampleCount(b);
            after=NaN; rewind=NaN;
            if b<numel(reacq)
                after=tr.absoluteSample(b+1); rewind=before-after;
                assert(rewind>=1 && rewind<=round(s.samplingFreq*.001), ...
                    'ReacqAudit:Alignment','Handover outside tail code period.');
            end
            lastCno=floor((a-1)/s.CNoInterval); bins=max(1,lastCno-2):lastCno;
            events{j}=struct('firstEpoch',a,'lastEpoch',b,'durationMs',b-a+1, ...
                'physicalStartSeconds',tr.absoluteSample(a)/s.samplingFreq, ...
                'precedingGuardWindowEpochs',[w(1) w(end)], ...
                'nearLimitOccupancy',mean(near),'guardOccupancyThreshold',s.pllSaturationRatio, ...
                'consistentWithPllSaturationGuard',mean(near)>=s.pllSaturationRatio, ...
                'precedingStoredTotalCno',tr.B2a_CNo(bins), ...
                'logicalBefore',before,'logicalResume',after,'rewindSamples',rewind, ...
                'invalidFrontendMs',nnz(tr.frontendBoundaryFlag(a:b) | ...
                    tr.frontendValidCount(a:b)~=tr.frontendSampleCount(a:b)));
        end
        records{k}=struct('mode',modes{k},'eventCount',numel(first), ...
            'pllMaxNcoHz',s.pllMaxNcoHz,'pllSaturationHoldMs',s.pllSaturationHoldMs, ...
            'pllSaturationNcoRatio',s.pllSaturationNcoRatio,'pllSaturationRatio',s.pllSaturationRatio, ...
            'TrkCN0Th',s.TrkCN0Th,'events',{events});
        t=tr.absoluteSample/s.samplingFreq; keep=t>=570 & t<=580;
        nco=tr.pllDiscrFilt; carrier=tr.carrFreq;
        nco(reacq)=NaN; carrier(reacq)=NaN;
        plot(ax1,t(keep),nco(keep),'DisplayName',modes{k});
        plot(ax2,t(keep),carrier(keep),'DisplayName',modes{k});
        index=s.CNoInterval:s.CNoInterval:numel(tr.I_P);
        tc=(tr.absoluteSample(index)+tr.frontendSampleCount(index))/s.samplingFreq;
        keepC=tc>=570 & tc<=580;
        pilot=tr.PilotCNo(1:numel(index)); pilot(pilot<=0)=NaN;
        % A stored estimate averages two 200-ms windows. Do not join through
        % the REACQ/mixed restart window as though it were a valid C/N0 dip.
        good=~reacq & ~tr.frontendBoundaryFlag & ...
            tr.frontendValidCount==tr.frontendSampleCount;
        good=all(reshape(good(1:index(end)),s.CNoInterval,[]),1);
        good=good & [false good(1:end-1)]; pilot(~good)=NaN;
        plot(ax3,tc(keepC),pilot(keepC),'.-','DisplayName',modes{k});
        clear loaded tr
    end
    title(ax1,'Archived PLL NCO around the TF400 event'); ylabel(ax1,'PLL NCO (Hz)');
    title(ax2,'Carrier frequency (internal tracking observable)'); ylabel(ax2,'Hz');
    title(ax3,'Native pilot C/N0'); ylabel(ax3,'dB-Hz'); xlabel(ax3,'Physical file time (s)');
    for ax=[ax1 ax2 ax3], grid(ax,'on'); legend(ax,'Location','best','Interpreter','none'); end
    exportgraphics(f,fullfile(outputRoot,'reacq_event.png'),'Resolution',150);
    audit=struct('scriptHash',frontendHash(fileread([mfilename('fullpath') '.m'])), ...
        'note','Guard consistency from saved NCO; no truth claim or threshold retuning.', ...
        'runs',{records});
    fid=fopen(fullfile(outputRoot,'reacq_audit.json'),'w','n','UTF-8'); cleanup=onCleanup(@() fclose(fid));
    fprintf(fid,'%s\n',jsonencode(audit,'PrettyPrint',true));
end
