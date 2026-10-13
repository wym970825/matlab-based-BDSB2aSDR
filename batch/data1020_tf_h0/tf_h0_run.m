function tf_h0_run()
root='F:/matlab-GNSSsdr/BDS/B2a';cd(root);setupPaths;addpath('batch/data1020_pb_s4');
out=string(fullfile(root,'results/data1020/20261010_tf_h0_20s'));
fid=fopen(fullfile(out,'started.md'),'w','n','UTF-8');fprintf(fid,'# TF H0 short tests started\n\nUTC: %s\n',string(datetime('now','TimeZone','UTC')));fclose(fid);
set(groot,'defaultFigureVisible','off');load(fullfile(out,'prepared.mat'),'cases');
labels=["PB_original","TF_original_800k_3us","TF_H0_800k_3us",compose("TF_H0_spectrum_%dus",1:5)];
rows=table();allWindows=cell(3,8,3);
for k=1:3
    c=cases{k};
    for v=1:numel(labels)
        cfg=c.settings;
        folder=fullfile(out,sprintf('%02d_%s',c.entry.experimentNumber,labels(v)));mkdir(folder);
        cfg.outDir=char(folder);cfg.resultRoot='';cfg.tempdataSvPth=char(fullfile(folder,'temp'));
        mkdir(cfg.tempdataSvPth);cfg.tag=char(labels(v));
        if v==1
            cfg.Frontend=struct('mode','pb');
        else
            width=800e3;span=3;center=c.entry.station.frequencyHz-c.entry.centerFrequencyHz;
            threshold=c.settings.PB_settings.Th_static_tracking;
            if v>=3,threshold=c.threshold;end
            if v>=4,width=c.bandwidthHz;span=v-3;center=c.centerHz;end
            cfg.Frontend=struct('mode','tf_v1','TF',struct('centerHz',center,'stopbandWidthHz',width, ...
                'thresholdAmplitude',threshold,'triangleSpanUs',span));
        end
        cfg=resolveFrontendSettings(cfg);save(fullfile(folder,'settings.mat'),'cfg');
        for j=1:numel(c.prns)
            p=c.prns(j);ch=c.channel([c.channel.PRN]==p);
            fprintf('\nExperiment %02d / %s / PRN %02d\n',c.entry.experimentNumber,labels(v),p);
            [path,~]=trackOneChannel(ch,cfg,j,numel(c.prns),true);
            saved=load(path,'finalTRes');t=saved.finalTRes;
            w=windows(t,cfg);allWindows{k,v,j}=w;
            st=double(t.trk_state(:));reacq=nnz(diff([false;st==9])==1);
            r=table(c.entry.experimentNumber,labels(v),p,numel(t.absoluteSample),reacq,height(w), ...
                median(w.B2aCno),median(w.PilotCno),mean(double(t.frontendDetectorDuty),'omitnan'), ...
                mean(double(t.frontendMeanWeight),'omitnan'), ...
                'VariableNames',{'Experiment','Variant','PRN','RecordedMs','ReacqEpisodes','ValidCnoWindows', ...
                'MedianB2aCno','MedianPilotCno','DetectorDuty','MeanWeight'});
            rows=[rows;r]; %#ok<AGROW>
            save(fullfile(out,'progress.mat'),'rows','allWindows','labels','cases','-v7.3');
            data1020_write_md(fullfile(out,'progress.md'),rows,'20秒跟踪进度与各自有效窗');
            clear saved t
        end
    end
end
paired=table();pairwise=table();
for k=1:3
    for j=1:3
        common=allWindows{k,1,j}.Bin;
        for v=2:8,common=intersect(common,allWindows{k,v,j}.Bin);end
        reference=allWindows{k,1,j};[~,ix]=ismember(common,reference.Bin);ref=reference(ix,:);
        for v=1:8
            candidate=allWindows{k,v,j};
            pairBins=intersect(reference.Bin,candidate.Bin);
            [~,ri]=ismember(pairBins,reference.Bin);[~,vi]=ismember(pairBins,candidate.Bin);
            a=reference(ri,:);b=candidate(vi,:);pairedTime=abs(a.FileSeconds-b.FileSeconds)<.002;
            pairrow=table(cases{k}.entry.experimentNumber,labels(v),cases{k}.prns(j),nnz(pairedTime), ...
                median(b.B2aCno(pairedTime)-a.B2aCno(pairedTime)), ...
                median(b.PilotCno(pairedTime)-a.PilotCno(pairedTime)), ...
                'VariableNames',{'Experiment','Variant','PRN','PairwiseWindows','DeltaB2aVsPB','DeltaPilotVsPB'});
            pairwise=[pairwise;pairrow]; %#ok<AGROW>
            w=allWindows{k,v,j};[~,ix]=ismember(common,w.Bin);w=w(ix,:);
            aligned=abs(w.FileSeconds-ref.FileSeconds)<.002;
            r=table(cases{k}.entry.experimentNumber,labels(v),cases{k}.prns(j),nnz(aligned), ...
                median(w.B2aCno(aligned)),median(w.PilotCno(aligned)), ...
                median(w.B2aCno(aligned)-ref.B2aCno(aligned)), ...
                median(w.PilotCno(aligned)-ref.PilotCno(aligned)), ...
                'VariableNames',{'Experiment','Variant','PRN','CommonWindows','B2aCno','PilotCno','DeltaB2aVsPB','DeltaPilotVsPB'});
            paired=[paired;r]; %#ok<AGROW>
        end
    end
end
data1020_write_md(fullfile(out,'paired_cno.md'),paired,'相同物理时间窗的CNo比较');
data1020_write_md(fullfile(out,'pairwise_vs_pb.md'),pairwise,'各配置与原PB两两共同窗口');
ranking=table();
for k=1:3
    id=cases{k}.entry.experimentNumber;
    for v=1:8
        a=paired(paired.Experiment==id & paired.Variant==labels(v),:);
        b=rows(rows.Experiment==id & rows.Variant==labels(v),:);
        r=table(id,labels(v),median(a.DeltaB2aVsPB),median(a.DeltaPilotVsPB),min(a.CommonWindows), ...
            sum(b.ReacqEpisodes),all(b.RecordedMs==20000), ...
            'VariableNames',{'Experiment','Variant','MedianSatelliteDeltaB2a','MedianSatelliteDeltaPilot', ...
            'MinCommonWindows','ReacqEpisodes','AllTracksComplete'});
        ranking=[ranking;r]; %#ok<AGROW>
    end
    a=ranking(ranking.Experiment==id,:);f=figure('Visible','off','Color','w','Position',[50 50 1100 480]);
    bar([a.MedianSatelliteDeltaB2a,a.MedianSatelliteDeltaPilot]);xticks(1:8);xticklabels(labels);xtickangle(25);
    ylabel('Paired C/N_0 difference from original PB (dB-Hz)');legend('B2a','Pilot','Location','best');grid on;
    title(sprintf('Experiment %02d / 20 s / PRN 27,38,41',id));
    exportgraphics(f,fullfile(out,sprintf('cno_%02d.png',id)),'Resolution',180);close(f);
    f=figure('Visible','off','Color','w','Position',[50 50 1100 850]);lay=tiledlayout(f,3,1,'TileSpacing','compact');
    for j=1:3
        ax=nexttile(lay);hold(ax,'on');
        for v=1:8
            w=allWindows{k,v,j};plot(ax,w.FileSeconds,w.B2aCno,'-o','MarkerSize',2);
        end
        ylabel(ax,'B2a C/N_0 (dB-Hz)');title(ax,sprintf('PRN %02d',cases{k}.prns(j)));grid(ax,'on');
        if j==1,legend(ax,labels,'Interpreter','none','Location','eastoutside');end
    end
    xlabel(ax,'Source-file time (s)');
    exportgraphics(f,fullfile(out,sprintf('cno_timeseries_%02d.png',id)),'Resolution',180);close(f);
end
data1020_write_md(fullfile(out,'cno_summary.md'),ranking,'三实验CNo比较汇总');
fid=fopen(fullfile(out,'selection.md'),'w','n','UTF-8');fprintf(fid,'# 20秒短测参数选择\n\n');
for k=1:3
    id=cases{k}.entry.experimentNumber;
    use=ranking.Experiment==id & startsWith(ranking.Variant,"TF_H0_spectrum_") & ...
        ranking.AllTracksComplete & ranking.ReacqEpisodes==0 & ranking.MinCommonWindows>0 & ...
        isfinite(ranking.MedianSatelliteDeltaB2a);
    a=sortrows(ranking(use,:),{'MedianSatelliteDeltaB2a','MedianSatelliteDeltaPilot'},{'descend','descend'});
    if height(a)>0
        fprintf(fid,'- 实验%02d：短测最高B2a C/N0配置 `%s`，谱陷波全宽 %.0f kHz；相对原PB的配对B2a差值 %.4f dB-Hz，Pilot差值 %.4f dB-Hz。\n', ...
            id,a.Variant(1),cases{k}.bandwidthHz/1e3,a.MedianSatelliteDeltaB2a(1),a.MedianSatelliteDeltaPilot(1));
    else
        fprintf(fid,'- 实验%02d：没有同时满足完整跟踪、无重捕及共同C/N0窗口的谱带宽候选。\n',id);
    end
end
fclose(fid);
save(fullfile(out,'comparison.mat'),'rows','paired','pairwise','ranking','allWindows','cases','labels','-v7.3');
fid=fopen(fullfile(out,'completion.md'),'w','n','UTF-8');
fprintf(fid,'# 20秒测试完成\n\nUTC：%s\n\n72条跟踪，24个配置。见 cno_summary.md、paired_cno.md。\n',string(datetime('now','TimeZone','UTC')));fclose(fid);
end

function w=windows(t,cfg)
ci=double(t.CNoInterval);n=numel(t.absoluteSample);
b=double(t.B2a_CNo(:));p=double(t.PilotCNo(:));ends=(1:min(numel(b),numel(p)))'*ci;
ends=ends(ends<=n);b=b(1:numel(ends));p=p(1:numel(ends));
sample=double(t.absoluteSample(:));time=sample(ends)/cfg.samplingFreq;
bin=round((time-sample(1)/cfg.samplingFreq)/.2);
valid=isfinite(b) & b>0 & isfinite(p) & p>0 & bin>=26 & bin<=100;
for z=find(valid)'
    ix=(ends(z)-2*ci+1):ends(z);
    valid(z)=all(ismember(double(t.trk_state(ix)),[3 4])) && ...
        all(diff(sample(ix))>0 & diff(sample(ix))<1.5*cfg.samplingFreq*.001);
end
w=table(bin(valid),time(valid),b(valid),p(valid),'VariableNames',{'Bin','FileSeconds','B2aCno','PilotCno'});
[~,uniqueIndex]=unique(w.Bin,'stable');w=w(uniqueIndex,:);
end
