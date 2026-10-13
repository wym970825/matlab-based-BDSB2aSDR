function data1020_main()
set(groot,'defaultFigureVisible','off');
started=fopen('F:/matlab-GNSSsdr/BDS/S4repair_basedOnSDR-v2/results/data1020_pb_02_04_05_s4/main_started.md','w','n','UTF-8');
fprintf(started,'# 主脚本开始执行\n\nUTC：%s\n\nMATLAB：%s\n',string(datetime('now','TimeZone','UTC')),version);
fclose(started);
[cases,out]=data1020_config();
fprintf('# DATA1020 PB S4 main\n\nStarted UTC: %s\n',string(datetime('now','TimeZone','UTC')));
mkdir(fullfile(out,'tables')); allTables=cell(3,1);allLinks=cell(3,1);summary=table();
index=fopen(fullfile(out,'index.html'),'w','n','UTF-8');
fprintf(index,'<!doctype html><meta charset="utf-8"><title>DATA1020 PB S4</title><style>body{font:16px Arial;max-width:1100px;margin:35px auto}img{max-width:95%%}a{color:#245baa}</style><h1>DATA1020 PB 02/04/05 S4</h1><p>UTC 2022-10-20 · Hardware validity forced true by configuration</p>');
for k=1:3
    c=cases{k}; folder=c.cfg.outputDir; mkdir(folder);mkdir(fullfile(folder,'tracks'));
    context=fullfile(folder,'receiver_context');mkdir(context);
    copyfile(fullfile(c.cfg.resultDir,'figures','navResult','*.png'),context);
    rows=cell(numel(c.cfg.prns),1); navLinks=rows;
    for j=1:numel(c.cfg.prns)
        p=c.cfg.prns(j); fprintf('\n## Experiment %02d PRN %02d\n',c.entry.experimentNumber,p);
        [t,d]=data1020_compute(c,p,Inf);
        [links,nav]=data1020_navigation(c,t,d);
        t.inside180SecondInterval=links.Inside180SecondInterval;
        t.navigationEpochs=links.NavigationEpochs;
        t.meanLatitude=links.MeanLatitude;t.meanLongitude=links.MeanLongitude;
        save(fullfile(folder,'tracks',sprintf('prn%02d.mat',p)),'t','d','links','-v7.3');
        data1020_write_md(fullfile(folder,'tracks',sprintf('prn%02d.md',p)),t,sprintf('实验%02d PRN%02d S4',c.entry.experimentNumber,p));
        rows{j}=t;navLinks{j}=links;
        v=t.comparisonValid;
        r=table(c.entry.experimentNumber,p,height(t),nnz(t.proposedValid),nnz(t.conventionalValid),nnz(v), ...
            mean(t.S4Observed(v)),mean(t.S4Conventional(v)),mean(t.S4Proposed(v)), ...
            nnz(t.radicandWasClipped(v)),nnz(t.conventionalWasClipped(v)), ...
            'VariableNames',{'Experiment','PRN','AllWindows','ProposedWindows','ConventionalWindows','CommonWindows', ...
            'MeanObserved','MeanConventional','MeanProposed','ProposedClipped','ConventionalClipped'});
        summary=[summary;r]; %#ok<AGROW>
        clear d
    end
    t=sortrows(vertcat(rows{:}),{'windowStartUtc','PRN'});links=vertcat(navLinks{:});
    save(fullfile(folder,'results.mat'),'t','links','nav','c','-v7.3');
    data1020_write_md(fullfile(folder,'all_windows.md'),t,'三种S4全部窗口');
    data1020_write_md(fullfile(folder,'navigation_window_links.md'),links,'S4窗口与导航位置');
    data1020_write_md(fullfile(context,'navigation_utc.md'),nav,'定位UTC与轨迹点');
    data1020_write_md(fullfile(folder,'common_windows.md'),t(t.comparisonValid,:),'三种S4共同有效窗口');
    figs=fullfile(folder,'publication_figures','gps_solutions');data1020_plot(t,figs,string(c.cfg.name));
    rel="experiments/"+c.cfg.name;
    fprintf(index,'<h2>%s</h2><p>Source: %s<br>Position UTC: %s — %s</p>',c.cfg.name,c.cfg.resultDir,c.entry.utcStart,c.entry.utcEnd);
    fprintf(index,'<img src="%s/receiver_context/lla_satellite_dme.png"><p>',rel);
    for name=["enu_displacement","enu_velocity","dop","sky_plot"]
        fprintf(index,'<a href="%s/receiver_context/%s.png">%s</a> · ',rel,name,name);
    end
    fprintf(index,'<a href="%s/all_windows.md">S4 tables</a> · <a href="%s/navigation_window_links.md">UTC/position links</a></p>',rel,rel);
    for p=c.cfg.prns
        fprintf(index,'<p><a href="%s/publication_figures/gps_solutions/prn%02d_s4.png">PRN %02d S4</a> · <a href="%s/publication_figures/gps_solutions/prn%02d_diagnostics.png">diagnostics</a></p>',rel,p,p,rel,p);
    end
    fprintf(index,'<img src="%s/publication_figures/gps_solutions/s4_summary.png">',rel);
    allTables{k}=t;allLinks{k}=links;
    fprintf('\nExperiment %02d finished.\n',c.entry.experimentNumber);
end
combined=sortrows(vertcat(allTables{:}),{'experimentNumber','windowStartUtc','PRN'});
navigationLinks=vertcat(allLinks{:});
data1020_write_md(fullfile(out,'tables','all_windows.md'),combined,'全部实验S4');
data1020_write_md(fullfile(out,'tables','summary.md'),summary,'逐实验逐星汇总');
data1020_write_md(fullfile(out,'tables','navigation_window_links.md'),navigationLinks,'UTC窗口与导航关联');
save(fullfile(out,'tables','results.mat'),'combined','summary','navigationLinks','cases','-v7.3');
fprintf(index,'<h2>Tables</h2><a href="tables/summary.md">Summary</a> · <a href="tables/all_windows.md">All windows</a><p>Completed UTC: %s</p>',string(datetime('now','TimeZone','UTC')));
fclose(index);
fid=fopen(fullfile(out,'completion.md'),'w','n','UTF-8');
fprintf(fid,'# 计算完成\n\nUTC：%s\n\n实验数：3；卫星组合：%d；分钟窗：%d；共同有效窗：%d。\n\n硬件有效性按批复强制置真；原判定保存为 hardwareRuleResult。\n', ...
    string(datetime('now','TimeZone','UTC')),height(summary),height(combined),nnz(combined.comparisonValid));fclose(fid);
fprintf('\nCompleted UTC: %s\n',string(datetime('now','TimeZone','UTC')));
end
