cd('F:/matlab-GNSSsdr/BDS/B2a'); setupPaths;
root='F:/matlab-GNSSsdr/BDS/B2a/results/data1020/20261008_static_pb_run02';
set(groot,'defaultFigureVisible','off');
folders=[dir(fullfile(root,'full_*'));dir(fullfile(root,'tail_*'));dir(fullfile(root,'smoke_*'))];
folders=folders([folders.isdir]);
items=cell(1,numel(folders));
timelines=struct([]);
for k=1:numel(folders)
    runDir=fullfile(folders(k).folder,folders(k).name);
    source=fullfile(runDir,'ui_results.mat');
    if ~isfile(source), continue; end
    S=load(source,'settings','results');
    if isfield(S.results,'navSolutions') && ~isempty(S.results.navSolutions)
        navTrack=navTrackTimeOrder(S.results.navSolutions,S.settings);
        navAudit=struct('plottedTrajectoryPoints',navTrack.n, ...
            'removedJumpPoints',navTrack.nRemovedJump, ...
            'maxSpeedMps',navTrack.maxSpeedMps);
        fid=fopen(fullfile(runDir,'navigation_plot_verification.json'),'w');
        fprintf(fid,'%s\n',jsonencode(navAudit,'PrettyPrint',true)); fclose(fid);
    end
    result=exportTrackingFiguresSequential(fullfile(runDir,'temp'),S.settings, ...
        fullfile(runDir,'figures','trkResult'),'Visible',false);
    assert(result.ok,'Failed to export tracking plots for %s',runDir);
    plotAcquisition(S.results.acqResults,S.settings.acqSatelliteList);
    fig=gcf; set(fig,'Visible','off','Position',[60 40 1800 1000]);
    axesList=findall(fig,'Type','axes');
    set(axesList,'FontSize',10,'XTickLabelRotation',90);
    set(findall(fig,'Type','legend'),'FontSize',11);
    exportgraphics(fig,fullfile(runDir,'figures','AcqResult', ...
        'acquisition_metrics.png'),'Resolution',140); close(fig);
    items{k}=struct('run',folders(k).name,'figureCount',numel(result.figureFiles), ...
        'ok',result.ok,'note', ...
        'State stairs recognized; all-PRN acquisition labels separated. Numerical results unchanged.');
    if startsWith(folders(k).name,'full_')
        files=dir(fullfile(runDir,'temp','Trk_Prn_*_final.mat'));
        for j=1:numel(files)
            T=load(fullfile(files(j).folder,files(j).name),'finalTRes');
            t=T.finalTRes;
            differences=diff(double(t.absoluteSample(:)));
            duplicateIdx=find(differences==0);
            states=double(t.trk_state(:));
            row=struct('run',folders(k).name,'PRN',t.PRN, ...
                'duplicateSampleSteps',nnz(differences==0), ...
                'backwardSampleSteps',nnz(differences<0), ...
                'allDuplicatesAtReacqExit',all(states(duplicateIdx)==9 & states(duplicateIdx+1)~=9), ...
                'sampleSpanSeconds',(t.absoluteSample(end)-t.absoluteSample(1))/S.settings.samplingFreq);
            if isempty(timelines), timelines=row; else, timelines(end+1)=row; end %#ok<SAGROW>
            clear T t
        end
    end
end
items=items(~cellfun(@isempty,items));
fid=fopen(fullfile(root,'figure_verification.json'),'w');
fprintf(fid,'%s\n',jsonencode([items{:}],'PrettyPrint',true)); fclose(fid);
fid=fopen(fullfile(root,'timeline_verification.json'),'w');
fprintf(fid,'%s\n',jsonencode(timelines,'PrettyPrint',true)); fclose(fid);
writetable(struct2table(timelines),fullfile(root,'timeline_verification.csv'));
export_data1020_offline_maps(root);
exit
