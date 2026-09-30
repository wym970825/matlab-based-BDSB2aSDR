function files=plot_semiphysical_review(runRoot)
% Standalone scientific plots; times are relative to each separate RF file.
runRoot=char(runRoot); reviewRoot=fullfile(runRoot,'review');
state=jsondecode(fileread(fullfile(runRoot,'supervisor.json')));
items=state.cases; if ~iscell(items), items=num2cell(items); end
colors=lines(5); labels={}; metrics=[];
f=figure('Visible','off','Color','w','Position',[100 100 1350 880]);
cleaner=onCleanup(@() close(f));
layout=tiledlayout(f,2,2,'TileSpacing','compact','Padding','compact');
axs=gobjects(1,4);
for j=1:4, axs(j)=nexttile(layout); hold(axs(j),'on'); grid(axs(j),'on'); end
for k=1:numel(items)
    item=items{k}; name=item.('case'); folder=fullfile(reviewRoot,name);
    if ~isfile(fullfile(folder,'data_review.json')), continue; end
    r=jsondecode(fileread(fullfile(folder,'data_review.json')));
    d=load(fullfile(item.outputDir,'temp','Trk_Prn_11_final.mat'),'finalTRes'); tr=d.finalTRes;
    t=(1:numel(tr.B2a_CNo))*0.2;
    plot(axs(1),t,movmean(tr.B2a_CNo,5,'omitnan'),'Color',colors(k,:),'DisplayName',name);
    count=floor(numel(tr.eta)/1000); t1=1:count;
    duty=mean(reshape(tr.eta(1:count*1000),1000,[]),1,'omitnan');
    phase=sqrt(mean(reshape((360*tr.pllDiscr(1:count*1000)).^2,1000,[]),1,'omitnan'));
    plot(axs(2),t1,100*duty,'Color',colors(k,:),'DisplayName',name);
    plot(axs(3),t1,phase,'Color',colors(k,:),'DisplayName',name);
    if isfile(fullfile(folder,'prn11_scint_corrected.mat'))
        replay=load(fullfile(folder,'prn11_scint_corrected.mat'),'scintReplay'); a=replay.scintReplay;
        plot(axs(4),a.TimeSec,a.IntensityS4Raw,'Color',colors(k,:),'DisplayName',name);
    end
    labels{end+1}=name; %#ok<AGROW>
    metrics(end+1,:)=[r.prn11.cnoTotalDbHz.median,100*r.prn11.pbDuty.mean, ...
        r.navigation.horizontalScatterM.p95,r.navigation.enuStdM(3)]; %#ok<AGROW>
end
titles={'Total C/N0 (1-second smoothing)','PB blanked samples (1-second mean)', ...
    'PLL discriminator RMS (1-second windows)','Intensity S4: raw, no thermal subtraction'};
ylabels={'dB-Hz','Blanking duty (%)','Degrees','S4'};
for j=1:4
    title(axs(j),titles{j}); ylabel(axs(j),ylabels{j}); xlim(axs(j),[0 715]);
    xlabel(axs(j),'Seconds from start of each RF recording');
end
ylim(axs(1),[20 60]);
legend(axs(1),'Location','southwest','Interpreter','none');
title(layout,sprintf('PRN 11 | %d/5 cases reviewed | recordings are not truth-aligned',numel(labels)));
files.tracking=fullfile(reviewRoot,'tracking_comparison.png');
exportgraphics(f,files.tracking,'Resolution',160);
exportgraphics(f,fullfile(reviewRoot,'tracking_comparison.pdf'),'ContentType','vector');
clear cleaner
f=figure('Visible','off','Color','w','Position',[100 100 1200 800]);
cleaner=onCleanup(@() close(f));
layout=tiledlayout(f,2,2,'TileSpacing','compact','Padding','compact');
titles={'PRN 11 median C/N0','PRN 11 average PB duty', ...
    '95th percentile horizontal scatter','Vertical standard deviation'};
ylabels={'dB-Hz','Percent','Metres relative to each run median','Metres relative to each run median'};
for j=1:4
    ax=nexttile(layout); bar(ax,metrics(:,j)); grid(ax,'on'); title(ax,titles{j}); ylabel(ax,ylabels{j});
    xticks(ax,1:numel(labels)); xticklabels(ax,labels); ax.TickLabelInterpreter='none'; xtickangle(ax,15);
end
title(layout,'Steady statistics (t >= 150 s); scatter is not absolute positioning accuracy');
files.statistics=fullfile(reviewRoot,'statistics_comparison.png');
exportgraphics(f,files.statistics,'Resolution',160);
exportgraphics(f,fullfile(reviewRoot,'statistics_comparison.pdf'),'ContentType','vector');
end
