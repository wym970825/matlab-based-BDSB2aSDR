function audit=audit_tf_bandwidth_states(runDirs,comparisonDir,outputRoot)
%AUDIT_TF_BANDWIDTH_STATES Archived NH confidence and full S4-window audit.
% No receiver rerun, parameter adjustment, or replacement of archived outputs.
    setupPaths();
    assert(numel(runDirs)==2 && ~isfolder(outputRoot));
    paired=load(fullfile(comparisonDir,'native_series.mat'),'series');
    runs=cell(1,2); masks=cell(1,2);
    for k=1:2
        rd=runDirs{k}; report=jsondecode(fileread(fullfile(rd,'report.json')));
        cfg=jsondecode(fileread(fullfile(rd,'validation_config.json')));
        loaded=load(fullfile(rd,['run_B2a_' report.tag '.mat']),'results');
        tr=trackResultsToStruct(loaded.results.trackResults); tr=tr([tr.PRN]==11);
        assert(isscalar(tr) && cfg.longCoh_ms==1 && cfg.pilotTRKflag==1);
        n=numel(tr.I_P); fs=cfg.samplingFreq;
        assert(~any(tr.trk_state==9),'Audit requires a continuous no-REACQ run.');
        isLong=logical(tr.cur_state(:)');
        first=[1 find(diff(isLong)~=0)+1]; last=[first(2:end)-1 n];
        intervals=arrayfun(@(a,b) struct('long',isLong(a),'firstEpoch',a, ...
            'lastEpoch',b,'durationMs',b-a+1,'firstFileTimeSec',tr.absoluteSample(a)/fs, ...
            'endFileTimeSec',(tr.absoluteSample(b)+tr.frontendSampleCount(b))/fs),first,last);

        % Undo the recorded pilot NH wipe-off with the phase recovered at
        % the preceding estimate. Replay only the 100-ms estimator windows.
        target=GenWeil(11); target=repmat(target(:),ceil((cfg.weilEstBuffLen+100)/100),1);
        phase=-1; anchor=-1; epoch=cfg.trackInit_MS; events={};
        while epoch<n
            ix=epoch-cfg.weilEstBuffLen+1:epoch;
            p=(tr.Pilot_I_P(ix)+1i*tr.Pilot_Q_P(ix))*exp(-1i*pi/2);
            if any(isLong(ix))
                assert(all(isLong(ix)) && phase>=0);
                nh=target(mod(phase+(ix-anchor),100)+1);
                p=p.*reshape(nh,size(p));
            end
            magnitude=zeros(100,1);
            for shift=0:99
                magnitude(shift+1)=abs(sum(p(:).*conj(target(shift+1:shift+numel(ix)))));
            end
            [peak,best]=max(magnitude); magnitude(best)=-inf;
            confidence=peak/(max(magnitude)+eps); success=confidence>=cfg.weilConfTh;
            assert(success==isLong(epoch+1),'Reconstructed NH decision differs from archive.');
            events{end+1}=struct('epoch',epoch,'fileTimeSec', ...
                (tr.absoluteSample(epoch)+tr.frontendSampleCount(epoch))/fs, ...
                'confidence',confidence,'threshold',cfg.weilConfTh,'success',success); %#ok<AGROW>
            if success
                phase=best-1; anchor=ix(1); epoch=epoch+cfg.reEstimateMS;
            else
                phase=-1; anchor=-1; epoch=epoch+cfg.trackInit_MS;
            end
        end
        stable=isLong & reshape(tr.frontendValidCount==tr.frontendSampleCount,1,[]) & ...
            ~reshape(tr.frontendBoundaryFlag,1,[]);
        ends=cfg.CNoInterval:cfg.CNoInterval:n; starts=ends-cfg.scint_bufLen+1;
        cumulative=[0 cumsum(~stable)]; eligible=starts>=1;
        full=false(size(ends));
        full(eligible)=cumulative(ends(eligible)+1)-cumulative(starts(eligible))==0;
        masks{k}=full;
        [~,label]=fileparts(rd);
        s4=tr.S4(1:numel(ends)); touched=find(isfinite(s4)&~full);
        runs{k}=struct('mode',label,'longIntervals',intervals,'nhEvents',{events}, ...
            'reconstructedNhDecisionsVerified',numel(events),'finiteS4Updates',nnz(isfinite(s4)), ...
            'finiteS4WithNonLongIn60sWindow',numel(touched), ...
            'affectedS4UpdateFileTimeSec',paired.series{k}.endTime(touched));
        clear loaded tr
    end
    x=paired.series{1}; y=paired.series{2}; [~,ix,iy]=intersect(x.key,y.key);
    mismatch=max(abs(x.startTime(ix)-y.startTime(iy)),abs(x.endTime(ix)-y.endTime(iy)));
    valid=x.valid(ix)&y.valid(iy)&mismatch<=2/min(x.fs,y.fs)+1e-12;
    common=valid & isfinite(x.s4(ix)) & isfinite(y.s4(iy));
    whole=common & masks{1}(ix)&masks{2}(iy);
    delta=y.s4(iy)-x.s4(ix); raw=y.s4Raw(iy)-x.s4Raw(ix);
    q=delta(whole);
    audit=struct('runs',{runs},'commonS4UsingCnoSupportOnly',nnz(common), ...
        'commonS4WithFull60sLongSupport',nnz(whole), ...
        'meanS4DifferenceFull60s',mean(q),'rmsS4DifferenceFull60s',sqrt(mean(q.^2)), ...
        'maximumAbsoluteS4DifferenceFull60s',max(abs(q)), ...
        'meanRawS4DifferenceFull60s',mean(raw(whole)), ...
        'excludedPairedS4FileTimeSec',max(x.endTime(ix(common&~whole)),y.endTime(iy(common&~whole))), ...
        'notes',['NH confidence reconstructed from archived pilot and preceding recovered NH phase; ' ...
        'every decision checked against next recorded state. Full 60-s LONG support is a sensitivity ' ...
        'screen, not an exact finite support bound on IIR detrending memory or an S4 truth test.'], ...
        'scriptHash',frontendHash(fileread([mfilename('fullpath') '.m'])));
    mkdir(outputRoot);
    fid=fopen(fullfile(outputRoot,'state_audit.json'),'w','n','UTF-8'); assert(fid>=0);
    cleanup=onCleanup(@() fclose(fid)); fprintf(fid,'%s\n',jsonencode(audit,'PrettyPrint',true));
end
