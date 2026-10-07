function export_data1020_offline_maps(root)
%EXPORT_DATA1020_OFFLINE_MAPS Export complete tracks without online tile loads.
    folders=[dir(fullfile(root,'full_*'));dir(fullfile(root,'tail_*'))];
    folders=folders([folders.isdir]);
    records=struct([]);
    for k=1:numel(folders)
        runDir=fullfile(folders(k).folder,folders(k).name);
        source=fullfile(runDir,'ui_results.mat');
        if ~isfile(source), continue; end
        S=load(source,'settings','results');
        if isempty(S.results.navSolutions), continue; end
        trk=navTrackTimeOrder(S.results.navSolutions,S.settings);
        if trk.n==0, continue; end
        fig=figure('Visible','off','Color','w','Position',[50 50 1200 900]);
        gx=geoaxes(fig); geobasemap(gx,'none'); hold(gx,'on');
        gx.FontSize=12;
        geoplot(gx,trk.lat,trk.lon,'-','Color',[.5 .5 .5], ...
            'LineWidth',1.2,'DisplayName','Track');
        elapsed=trk.t(:)-trk.t(1);
        if max(elapsed)>0, elapsed=elapsed/max(elapsed); end
        geoscatter(gx,trk.lat,trk.lon,20,elapsed,'filled', ...
            'HandleVisibility','off');
        geoscatter(gx,trk.lat(1),trk.lon(1),110,[.1 .75 .2],'filled', ...
            'Marker','o','MarkerEdgeColor','k','DisplayName','Start');
        geoscatter(gx,trk.lat(end),trk.lon(end),110,[.9 .2 .1],'filled', ...
            'Marker','square','MarkerEdgeColor','k','DisplayName','End');
        colormap(gx,turbo(256)); clim(gx,[0 1]);
        cb=colorbar(gx); cb.FontSize=12;
        cb.Label.String='Normalised elapsed time';
        title(gx,sprintf('%s | Longitude / latitude track | N=%d\nStart (%.5f, %.5f)  |  End (%.5f, %.5f)', ...
            folders(k).name,trk.n,trk.lat(1),trk.lon(1),trk.lat(end),trk.lon(end)), ...
            'Interpreter','none','FontSize',13);
        legend(gx,'Location','southoutside','Orientation','horizontal','FontSize',12);
        path=fullfile(runDir,'figures','navResult','lla_geobasemap.png');
        exportgraphics(fig,path,'Resolution',140); close(fig);
        row=struct('run',folders(k).name,'points',trk.n, ...
            'removedJumpPoints',trk.nRemovedJump,'basemap','none','path',path);
        if isempty(records), records=row; else, records(end+1)=row; end %#ok<AGROW>
        fprintf('Offline navigation map: %s (%d points)\n',folders(k).name,trk.n);
    end
    fid=fopen(fullfile(root,'offline_map_verification.json'),'w');
    assert(fid>0,'Cannot write map verification');
    fprintf(fid,'%s\n',jsonencode(records,'PrettyPrint',true)); fclose(fid);
end
