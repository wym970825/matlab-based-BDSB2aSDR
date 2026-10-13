function data1020_smoke()
set(groot,'defaultFigureVisible','off');
[cases,out]=data1020_config();
smoke=cell(4,1); tests=[1 27;2 27;3 24;3 28];
for k=1:4
    c=cases{tests(k,1)};
    [t,d]=data1020_compute(c,tests(k,2),1);
    [links,nav]=data1020_navigation(c,t,d);
    smoke{k}=t;
    save(fullfile(out,'preflight',sprintf('smoke_%02d_prn%02d.mat',c.entry.experimentNumber,tests(k,2))),'t','d','links','nav','-v7.3');
    data1020_write_md(fullfile(out,'preflight',sprintf('smoke_%02d_prn%02d.md',c.entry.experimentNumber,tests(k,2))),t,'Smoke分钟结果');
    data1020_write_md(fullfile(out,'preflight',sprintf('navigation_%02d_prn%02d.md',c.entry.experimentNumber,tests(k,2))),links,'Smoke UTC导航关联');
    assert(all(t.frontEndResponseVerified) && all(links.NavigationEpochs==120));
    good=isfinite(t.S4Proposed);
    assert(all(abs(t.S4Proposed(good).^2-max(t.correctionRadicand(good),0))<1e-10));
end
smokeTable=vertcat(smoke{:});
data1020_plot(smoke{1},fullfile(out,'preflight','figures'),'02 smoke');
save(fullfile(out,'preflight','preflight_complete.mat'),'cases','smokeTable','-v7.3');
data1020_write_md(fullfile(out,'preflight','smoke_summary.md'),smokeTable(:, ...
    {'experimentNumber','PRN','windowStartUtc','S4Observed','S4Conventional','S4Proposed', ...
    'frontEndResponseVerified','hardwareRuleResult','proposedValid','comparisonValid','qualityCode'}),'Smoke汇总');
fprintf('\nPreflight complete: 26 input tracks, 18 SSC blocks, 4 smoke windows.\n');
end
