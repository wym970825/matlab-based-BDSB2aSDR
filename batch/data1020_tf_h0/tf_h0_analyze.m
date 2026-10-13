function tf_h0_analyze()
cd('F:/matlab-GNSSsdr/BDS/B2a');addpath('batch/data1020_pb_s4');
out="F:/matlab-GNSSsdr/BDS/B2a/results/data1020/20261010_tf_h0_20s";
load(fullfile(out,'comparison.mat'),'allWindows','cases','labels','ranking');
dest=fullfile(out,'analysis');mkdir(dest);set(groot,'defaultFigureVisible','off');
audit=table();effects=table();details=table();missing=table();duty=table();
pairs=[2 1;3 2;6 3;4 6;5 6;7 6;8 6;6 2;4 2];
pairNames=["originalTF_minus_PB","H0_minus_originalTF","spectrum3_minus_H0800", ...
    "edge1_minus_edge3","edge2_minus_edge3","edge4_minus_edge3","edge5_minus_edge3", ...
    "spectrum3_minus_originalTF","spectrum1_minus_originalTF"];
for k=1:3
    id=cases{k}.entry.experimentNumber;
    for j=1:3
        p=cases{k}.prns(j);
        for v=1:8
            file=fullfile(out,sprintf('%02d_%s',id,labels(v)),'temp',sprintf('Trk_Prn_%02d_final.mat',p));
            s=load(file,'finalTRes');t=s.finalTRes;ci=t.CNoInterval;
            sample=double(t.absoluteSample(:));state=double(t.trk_state(:));
            last=(1:min(numel(t.B2a_CNo),numel(t.PilotCNo)))'*ci;last=last(last<=numel(sample));
            tm=sample(last)/20e6;bin=round((sample(last)-sample(1))/20e6/.2);
            b=double(t.B2a_CNo(:));b=b(1:numel(last));pilot=double(t.PilotCNo(:));pilot=pilot(1:numel(last));
            valid=bin>=26 & bin<=100 & isfinite(b) & b>0 & isfinite(pilot) & pilot>0;
            for z=find(bin>=26 & bin<=100)'
                ix=last(z)-2*ci+1:last(z);
                stable=all(ismember(state(ix),[3 4]));gap=any(diff(sample(ix))<=0 | diff(sample(ix))>=30000);
                valid(z)=valid(z) && stable && ~gap;
                if ~valid(z)
                    row=table(id,labels(v),p,tm(z),nnz(~ismember(state(ix),[3 4])),gap, ...
                        join(string(unique(state(ix)))',','),b(z),pilot(z),'VariableNames', ...
                        {'Experiment','Variant','PRN','EndpointFileSeconds','NonLongTicks','Gap','States','B2aCno','PilotCno'});
                    missing=[missing;row]; %#ok<AGROW>
                end
            end
            w=allWindows{k,v,j};
            same=isequal(bin(valid),w.Bin) && max(abs(b(valid)-w.B2aCno))<1e-10 && ...
                max(abs(pilot(valid)-w.PilotCno))<1e-10 && max(abs(tm(valid)-w.FileSeconds))<1e-10;
            reacq=nnz(diff([false;state==9])==1);
            extraNonLong=nnz(~ismember(state(3001:end),[3 4]));
            audit=[audit;table(id,labels(v),p,numel(sample),reacq,extraNonLong,height(w),same, ...
                'VariableNames',{'Experiment','Variant','PRN','Samples','Reacq','NonLongAfter3s','Windows','MatchesSaved'})]; %#ok<AGROW>
            count=double(t.frontendSampleCount(:));a=count/sum(count);
            duty=[duty;table(id,labels(v),p,100*sum(a.*double(t.frontendDetectorDuty(:))), ...
                100*sum(a.*double(t.frontendMeanWeight(:))),100*sum(a.*double(t.frontendWeightSupportFraction(:))), ...
                'VariableNames',{'Experiment','Variant','PRN','DetectorPercent','MeanWeightPercent','WeightSupportPercent'})]; %#ok<AGROW>
        end
        common=allWindows{k,1,j}.Bin;
        for v=2:8,common=intersect(common,allWindows{k,v,j}.Bin);end
        values=zeros(numel(common),2,8);endpoints=zeros(numel(common),8);
        for v=1:8
            w=allWindows{k,v,j};[~,ix]=ismember(common,w.Bin);
            values(:,:,v)=[w.B2aCno(ix),w.PilotCno(ix)];endpoints(:,v)=w.FileSeconds(ix);
        end
        assert(max(max(abs(endpoints-endpoints(:,1))))<.002);
        for z=1:size(pairs,1)
            delta=values(:,:,pairs(z,1))-values(:,:,pairs(z,2));
            row=table(id,p,pairNames(z),size(delta,1),median(delta(:,1)),median(delta(:,2)), ...
                prctile(delta(:,1),10),prctile(delta(:,1),90), ...
                'VariableNames',{'Experiment','PRN','Contrast','Windows','DeltaB2a','DeltaPilot','B2aP10','B2aP90'});
            details=[details;row]; %#ok<AGROW>
        end
    end
    for z=1:size(pairs,1)
        a=details(details.Experiment==id & details.Contrast==pairNames(z),:);
        effects=[effects;table(id,pairNames(z),median(a.DeltaB2a),median(a.DeltaPilot),min(a.DeltaB2a),max(a.DeltaB2a), ...
            'VariableNames',{'Experiment','Contrast','DeltaB2a','DeltaPilot','MinSatelliteB2a','MaxSatelliteB2a'})]; %#ok<AGROW>
    end
end
assert(height(audit)==72 && all(audit.MatchesSaved) && all(audit.Samples==20000));
data1020_write_md(fullfile(dest,'independent_audit.md'),audit,'72条原始跟踪复核');
data1020_write_md(fullfile(dest,'direct_effects.md'),effects,'同一时刻直接相减的参数效果');
data1020_write_md(fullfile(dest,'direct_effects_per_satellite.md'),details,'逐星直接配对参数效果');
data1020_write_md(fullfile(dest,'excluded_windows.md'),missing,'未进入共同载噪比比较的窗口');
data1020_write_md(fullfile(dest,'sample_weighted_duty.md'),duty,'按RF样点数加权的前端占空比');
save(fullfile(dest,'analysis.mat'),'audit','effects','details','missing','duty','-v7.3');
% Summary view: large PB/TF differences and the much smaller edge differences.
f=figure('Visible','off','Color','w','Position',[20 20 1350 460]);lay=tiledlayout(f,1,3,'Padding','compact');
for k=1:3
    ids=[2 4 5];ax=nexttile(lay);hold(ax,'on');
    a=ranking(ranking.Experiment==ids(k),:);
    plot(ax,1:8,a.MedianSatelliteDeltaB2a,'-o','LineWidth',1.3);
    plot(ax,1:8,a.MedianSatelliteDeltaPilot,'-s','LineWidth',1.3);
    yline(ax,0,':');xticks(ax,1:8);xticklabels(ax,{'PB','Old TF','H0 800','1 us','2 us','3 us','4 us','5 us'});xtickangle(ax,35);
    title(ax,sprintf('Experiment %02d',ids(k)));ylabel(ax,'Paired C/N_0 vs PB (dB-Hz)');grid(ax,'on');
    if k==1,legend(ax,'B2a','Pilot','Location','best');end
end
exportgraphics(f,fullfile(dest,'overall_cno.png'),'Resolution',180);close(f);
f=figure('Visible','off','Color','w','Position',[20 20 1350 460]);lay=tiledlayout(f,1,3,'Padding','compact');
for k=1:3
    ids=[2 4 5];ax=nexttile(lay);hold(ax,'on');
    names=["edge1_minus_edge3","edge2_minus_edge3","", "edge4_minus_edge3","edge5_minus_edge3"];
    y=zeros(5,2);
    for s=[1 2 4 5]
        a=effects(effects.Experiment==ids(k) & effects.Contrast==names(s),:);y(s,:)=[a.DeltaB2a,a.DeltaPilot];
    end
    plot(ax,1:5,y(:,1),'-o');plot(ax,1:5,y(:,2),'-s');yline(ax,0,':');grid(ax,'on');
    xticks(ax,1:5);xlabel(ax,'Outer edge span (us)');ylabel(ax,'Direct paired change from 3 us (dB-Hz)');
    title(ax,sprintf('Experiment %02d',ids(k)));if k==1,legend(ax,'B2a','Pilot','Location','best');end
end
exportgraphics(f,fullfile(dest,'edge_direct_effects.png'),'Resolution',180);close(f);
fprintf('Analysis complete: 72 raw MATs verified; direct effects and plots saved.\n');
end
