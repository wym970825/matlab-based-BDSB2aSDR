function detail=plot_tf_bandwidth_differences(comparisonDir,outputRoot)
%PLOT_TF_BANDWIDTH_DIFFERENCES Inspect matched differences without interpolation.
% Uses archived native-series outputs from compare_tf_validation.
    setupPaths();
    if nargin<2, outputRoot=fullfile(comparisonDir,'differences'); end
    assert(~isfolder(outputRoot),'TFDifference:OutputExists','Use a fresh output folder.');
    data=load(fullfile(comparisonDir,'native_series.mat'),'series','summary');
    assert(numel(data.series)==2,'TFDifference:Pair','Exactly two modes required.');
    x=data.series{1}; y=data.series{2};
    [~,ix,iy]=intersect(x.key,y.key);
    edge=max(abs(x.startTime(ix)-y.startTime(iy)),abs(x.endTime(ix)-y.endTime(iy)));
    overlap=max(0,min(x.endTime(ix),y.endTime(iy))-max(x.startTime(ix),y.startTime(iy)));
    span=max(x.endTime(ix)-x.startTime(ix),y.endTime(iy)-y.startTime(iy));
    valid=x.valid(ix)&y.valid(iy)&overlap./span>=.99;
    time=max(x.endTime(ix),y.endTime(iy));
    pilot=y.pilot(iy)-x.pilot(ix); total=y.total(iy)-x.total(ix);
    pilot(~valid)=NaN; total(~valid)=NaN;
    s4=y.s4(iy)-x.s4(ix); raw=y.s4Raw(iy)-x.s4Raw(ix);
    s4(~valid)=NaN; raw(~valid)=NaN;
    useS4=isfinite(s4); strict=valid & edge<=2/min(x.fs,y.fs)+1e-12;
    p=pilot(valid); q=s4(useS4);
    assert(nnz(valid)==data.summary.pairs{1}.commonCnoWindows);
    assert(abs(mean(p)-data.summary.pairs{1}.meanPilotDifferenceDb)<1e-12);
    detail=struct('comparison',[y.mode ' minus ' x.mode], ...
        'commonCnoUpdates',nnz(valid),'strictCnoUpdates',nnz(strict), ...
        'meanPilotDifferenceDb',mean(p),'medianPilotDifferenceDb',median(p), ...
        'pilotQuantiles05_50_95Db',quantile(p,[.05 .5 .95]), ...
        'fractionPositivePilotDifferences',mean(p>0), ...
        'commonS4Updates',nnz(useS4),'meanS4Difference',mean(q), ...
        'rmsS4Difference',sqrt(mean(q.^2)),'maximumAbsoluteS4Difference',max(abs(q)), ...
        'meanRawS4Difference',mean(raw,'omitnan'), ...
        'notes','Paired estimator differences, not errors against truth. Updates overlap in time.', ...
        'scriptHash',frontendHash(fileread([mfilename('fullpath') '.m'])));
    mkdir(outputRoot);
    fid=fopen(fullfile(outputRoot,'difference_summary.json'),'w','n','UTF-8');
    cleanup=onCleanup(@() fclose(fid)); fprintf(fid,'%s\n',jsonencode(detail,'PrettyPrint',true)); clear cleanup
    save(fullfile(outputRoot,'paired_differences.mat'),'time','pilot','total','s4','raw','valid','strict','detail');
    f=figure('Visible','off','Position',[100 100 1150 850]); cleanup=onCleanup(@() close(f));
    tiledlayout(3,1);
    nexttile; plot(time,pilot,'-'); hold on; yline(0,':');
    ylabel('Pilot C/N0 difference (dB)'); title(detail.comparison,'Interpreter','none'); grid on;
    nexttile; hold on;
    for field={'blocks60','blocks120'}
        b=data.summary.pairs{1}.(field{1});
        plot(b.blockEndSeconds-b.blockLengthSec/2,b.pilotMeanDifferencesDb,'o-', ...
            'DisplayName',sprintf('%g-s blocks',b.blockLengthSec));
    end
    yline(0,':','HandleVisibility','off'); ylabel('Block mean difference (dB)');
    title('Blocks with at least 98% matched coverage'); legend('Location','best'); grid on;
    nexttile; plot(time,s4,'.','DisplayName','Corrected S4'); hold on;
    plot(time,raw,'.','DisplayName','Uncorrected S4');
    yline(0,':','HandleVisibility','off'); ylabel('S4 difference');
    xlabel('Physical file time (s)'); legend('Location','best'); grid on;
    exportgraphics(f,fullfile(outputRoot,'paired_differences.png'),'Resolution',150);
end
