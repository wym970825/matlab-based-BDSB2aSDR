function records = export_data1020_satellite_maps(manifestPath)
%EXPORT_DATA1020_SATELLITE_MAPS Offline, paired PB/TF maps with DME sites.
% The manifest has outputRoot, analysisDir and entries. Each entry provides
% experimentNumber, sourceId, pbDir, tfDir, utcStart, requestedMs and station
% (name, id, frequencyHz, latitude, longitude). Optional mapStations adds
% explicit additional candidate sites. Numerical receiver outputs are read
% only; the standard navigation-map PNG is replaced by the requested map.
% Satellite tiles are downloaded once, checked as complete JPEGs and cached.
% No geoaxes asynchronous load, visible figure or parallel pool is used.

    manifestPath = char(manifestPath);
    manifest = jsondecode(fileread(manifestPath));
    scriptDir = fileparts(mfilename('fullpath'));
    repoRoot = fileparts(scriptDir);
    addpath(scriptDir,fullfile(repoRoot,'include'));
    outputRoot = char(manifest.outputRoot);
    if isfield(manifest,'analysisDir') && ~isempty(manifest.analysisDir)
        auditDir = fullfile(char(manifest.analysisDir),'satellite_maps');
    else
        auditDir = fullfile(outputRoot,'analysis','satellite_maps');
    end
    if ~isfolder(auditDir), mkdir(auditDir); end
    cacheDir = fullfile(outputRoot,'satellite_tile_cache');
    [colors,palette] = data1020_purple_orange();
    records = struct([]);
    for k = 1:numel(manifest.entries)
        entry = manifest.entries(k);
        if ~isfield(entry,'station') || isempty(entry.station), continue; end
        stations = entry.station;
        if isfield(entry,'mapStations') && ~isempty(entry.mapStations)
            stations = entry.mapStations;
        end
        methods = {'PB','TF'};
        paths = {localText(entry,'pbDir'),localText(entry,'tfDir')};
        tracks = cell(1,2);
        rawCounts = zeros(1,2);
        latAll = [stations.latitude].'; lonAll = [stations.longitude].';
        for method = 1:2
            source = fullfile(paths{method},'ui_results.mat');
            if isempty(paths{method}) || ~isfile(source), continue; end
            saved = load(source,'settings','results');
            if ~isfield(saved,'results') || ~isfield(saved.results,'navSolutions') ...
                    || isempty(saved.results.navSolutions)
                continue;
            end
            nav = saved.results.navSolutions;
            tracks{method} = navTrackTimeOrder(nav,saved.settings);
            rawCounts(method) = nnz(isfinite(nav.latitude) & isfinite(nav.longitude));
            if tracks{method}.n == 0, tracks{method} = []; continue; end
            latAll = [latAll;tracks{method}.lat(:)]; %#ok<AGROW>
            lonAll = [lonAll;tracks{method}.lon(:)]; %#ok<AGROW>
        end
        if all(cellfun(@isempty,tracks)), continue; end
        contentBounds = [min(lonAll),min(latAll),max(lonAll),max(latAll)];
        center = [mean(contentBounds([1,3])),mean(contentBounds([2,4]))];
        halfLon = max(diff(contentBounds([1,3]))/2,0.001)*1.20;
        halfLat = max(diff(contentBounds([2,4]))/2,0.001)*1.20;
        xLimits = localX(center(1)+[-halfLon,halfLon]);
        yCenter = localY(center(2));
        yCandidates = localY(center(2)+[-halfLat,halfLat]);
        halfY = max(abs(yCandidates-yCenter));
        yLimits = yCenter+[-halfY,halfY];
        geographicBounds = [localLongitude(xLimits(1)),localLatitude(yLimits(1)), ...
            localLongitude(xLimits(2)),localLatitude(yLimits(2))];
        prefix = sprintf('experiment_%02d',entry.experimentNumber);
        tileManifestPath = fullfile(auditDir,[prefix '_tiles.json']);
        requestPath = fullfile(auditDir,[prefix '_tile_request.json']);
        request = struct('cacheDir',cacheDir,'bounds',geographicBounds, ...
            'manifestPath',tileManifestPath);
        localJson(requestPath,request);
        pythonScript = fullfile(scriptDir,'cache_data1020_satellite_tiles.py');
        command = sprintf('python "%s" "%s"',pythonScript,requestPath);
        [status,message] = system(command);
        assert(status==0,'data1020:SatelliteDownload','Satellite tile caching failed: %s',message);
        fprintf('%s',message);
        tileManifest = jsondecode(fileread(tileManifestPath));
        [mosaic,imageX,imageY] = localMosaic(tileManifest);
        assert(max(size(mosaic,1),size(mosaic,2))<=2816, ...
            'data1020:MapMemory','Satellite mosaic exceeded the memory limit.');
        for method = 1:2
            if isempty(tracks{method}), continue; end
            trk = tracks{method};
            outDir = fullfile(paths{method},'figures','navResult');
            if ~isfolder(outDir), mkdir(outDir); end
            [fig,pointTable] = localFigure(entry,methods{method},trk,stations, ...
                colors,mosaic,imageX,imageY,xLimits,yLimits,tileManifest.attribution);
            cleanup = onCleanup(@() close(fig));
            pngPath = fullfile(outDir,'lla_satellite_dme.png');
            exportgraphics(fig,pngPath,'Resolution',170);
            copyfile(pngPath,fullfile(outDir,'lla_geobasemap.png'),'f');
            writetable(pointTable,fullfile(outDir,'satellite_track_points.csv'));
            row = struct('experimentNumber',entry.experimentNumber, ...
                'sourceId',entry.sourceId,'method',methods{method}, ...
                'runDir',paths{method},'png',pngPath,'rawFinitePoints',rawCounts(method), ...
                'plottedPoints',trk.n,'removedJumpPoints',trk.nRemovedJump, ...
                'maxEnuComponentSpeedMps',trk.maxSpeedMps,'stations',stations, ...
                'stationMatchIsWeak',isfield(entry,'stationMatchIsWeak') && logical(entry.stationMatchIsWeak), ...
                'contentBoundsWestSouthEastNorth',contentBounds, ...
                'mapBoundsWestSouthEastNorth',geographicBounds, ...
                'mapCenterLongitudeLatitude',center, ...
                'pairedBoundsIncludePB',~isempty(tracks{1}), ...
                'pairedBoundsIncludeTF',~isempty(tracks{2}), ...
                'paddingFractionPerSide',0.10,'projection','EPSG:3857 / Web Mercator', ...
                'tileManifest',tileManifestPath,'tileZoom',tileManifest.zoom, ...
                'mosaicPixels',[size(mosaic,2),size(mosaic,1)], ...
                'attribution',tileManifest.attribution,'palette',palette, ...
                'filterNote',sprintf(['Same navTrackTimeOrder plotting filter as receiver; ' ...
                'finite latitude/longitude then iterative %.0f m/s component-jump filter; ' ...
                'raw MAT and NMEA navigation remain unchanged.'],trk.maxSpeedMps));
            localJson(fullfile(outDir,'satellite_map_metadata.json'),row);
            if isempty(records), records=row; else, records(end+1)=row; end %#ok<AGROW>
            fprintf('Satellite map %02d %s: %d points, %d removed, %d tiles\n', ...
                entry.experimentNumber,methods{method},trk.n,trk.nRemovedJump,tileManifest.tileCount);
            clear cleanup fig;
        end
        clear mosaic;
    end
    localJson(fullfile(auditDir,'satellite_map_verification.json'),records);
end

function [fig,points] = localFigure(entry,method,trk,stations,colors,mosaic, ...
        imageX,imageY,xLimits,yLimits,attribution)
    aspect = diff(xLimits)/diff(yLimits);
    if aspect>=1
        mapWidth = 1160; mapHeight = 1160/aspect;
    else
        mapHeight = 900; mapWidth = 900*aspect;
    end
    % Keep the axes rectangle at its exact geographic aspect ratio. A
    % minimum axes height/width would cause daspect to shrink its plot box
    % while leaving the manually positioned colorbar at the larger size.
    % Extra space for titles belongs to the figure, not to the map box.
    figureWidth = max(900,mapWidth+240); figureHeight = mapHeight+225;
    mapLeft = (figureWidth-mapWidth-56)/2;
    fig = figure('Visible','off','Color','w','Position',[20 20 figureWidth figureHeight], ...
        'DefaultAxesFontName','Arial','DefaultTextFontName','Microsoft YaHei');
    axPosition = [mapLeft 122 mapWidth mapHeight]./[figureWidth figureHeight figureWidth figureHeight];
    ax = axes(fig,'Position',axPosition,'YDir','normal','FontSize',11);
    image(ax,'XData',imageX,'YData',imageY,'CData',mosaic);
    hold(ax,'on');
    x = localX(trk.lon(:)); y = localY(trk.lat(:));
    elapsed = trk.t(:)-trk.t(1);
    plot(ax,x,y,'w-','LineWidth',3.8,'HandleVisibility','off');
    surface(ax,[x x],[y y],zeros(numel(x),2),[elapsed elapsed], ...
        'FaceColor','none','EdgeColor','interp','LineWidth',2.2, ...
        'HandleVisibility','off');
    scatter(ax,x,y,14,elapsed,'filled','HandleVisibility','off');
    startHandle = plot(ax,x(1),y(1),'o','MarkerSize',8, ...
        'MarkerFaceColor',colors(1,:),'MarkerEdgeColor','w','LineWidth',1.5);
    endHandle = plot(ax,x(end),y(end),'s','MarkerSize',8, ...
        'MarkerFaceColor',colors(end,:),'MarkerEdgeColor','w','LineWidth',1.5);
    for k=1:numel(stations)
        station = stations(k);
        sx = localX(station.longitude); sy = localY(station.latitude);
        plot(ax,sx,sy,'^','MarkerSize',13,'MarkerFaceColor',[.12 .8 1], ...
            'MarkerEdgeColor','w','LineWidth',1.5,'HandleVisibility','off');
        align = 'left'; dx = .015*diff(xLimits);
        if sx>mean(xLimits), align='right'; dx=-dx; end
        stationLabel = station.name;
        if isfield(entry,'stationMatchIsWeak') && entry.stationMatchIsWeak ...
                && strcmp(station.id,entry.station.id)
            stationLabel = [char(stationLabel) '（候选）'];
        end
        label = sprintf('%s DME  %.0f MHz',stationLabel,station.frequencyHz/1e6);
        text(ax,sx+dx,sy+.025*diff(yLimits),label,'Color','k','FontSize',11, ...
            'FontName','Microsoft YaHei','FontWeight','bold','Interpreter','none', ...
            'HorizontalAlignment',align,'BackgroundColor','w','Margin',4,'Clipping','on');
    end
    view(ax,2); xlim(ax,xLimits); ylim(ax,yLimits);
    ax.YDir='normal'; ax.Layer='top'; ax.Box='on';
    % Exact limits and plot-box dimensions match Web Mercator geometry.
    daspect(ax,[1 1 1]);
    longitudeTickCount=5;
    if mapWidth<500, longitudeTickCount=3; end
    lonTicks = linspace(localLongitude(xLimits(1)),localLongitude(xLimits(2)),longitudeTickCount);
    latTicks = linspace(localLatitude(yLimits(1)),localLatitude(yLimits(2)),5);
    xticks(ax,localX(lonTicks)); yticks(ax,localY(latTicks));
    longitudeFormat='%.3f° E'; latitudeFormat='%.3f° N';
    if min(diff(lonTicks))<0.002, longitudeFormat='%.4f° E'; end
    if min(diff(latTicks))<0.002, latitudeFormat='%.4f° N'; end
    xticklabels(ax,compose(longitudeFormat,lonTicks));
    yticklabels(ax,compose(latitudeFormat,latTicks));
    xlabel(ax,'Longitude (WGS 84)'); ylabel(ax,'Latitude (WGS 84)');
    colormap(ax,colors); clim(ax,[0 max(1,double(entry.requestedMs)/1000)]);
    cb = colorbar(ax,'Position',[(mapLeft+mapWidth+25)/figureWidth,122/figureHeight, ...
        17/figureWidth,mapHeight/figureHeight]);
    cb.Label.String='Elapsed time (s)'; cb.FontSize=10;
    if mapHeight<240
        cb.Ticks=linspace(0,max(1,double(entry.requestedMs)/1000),3);
        cb.TickLabels=compose('%.0f',cb.Ticks);
    end
    ax.Position=axPosition;
    title(ax,{sprintf('Experiment %02d  |  %s  |  %s', ...
        entry.experimentNumber,method,entry.sourceId), ...
        sprintf('UTC start: %s  |  plotted %d fixes; jump-filtered %d', ...
        localText(entry,'utcStart'),trk.n,trk.nRemovedJump)}, ...
        'FontSize',13,'FontWeight','normal','Interpreter','none');
    lg = legend(ax,[startHandle,endHandle],{'Start','End'}, ...
        'Location','southoutside','Orientation','horizontal','Box','off');
    lg.Position = [mapLeft/figureWidth,48/figureHeight,mapWidth/figureWidth,30/figureHeight];
    ax.Position=axPosition;
    annotation(fig,'textbox',[.025 .013 .95 .04],'String',attribution, ...
        'Interpreter','none','EdgeColor','none','FontSize',8,'Color',[.25 .25 .25], ...
        'HorizontalAlignment','center','Margin',0);
    drawnow;
    points = table(trk.idx(:),trk.t(:),elapsed,trk.lat(:),trk.lon(:), ...
        trk.h(:),trk.PDOP(:),'VariableNames',{'navigationEpochIndex', ...
        'epochElapsedSeconds','colorElapsedSeconds','latitudeDeg', ...
        'longitudeDeg','heightM','PDOP'});
end

function [mosaic,imageX,imageY] = localMosaic(metadata)
    nx=metadata.xMax-metadata.xMin+1; ny=metadata.yMax-metadata.yMin+1;
    mosaic=zeros(ny*256,nx*256,3,'uint8');
    for k=1:numel(metadata.tiles)
        tile=metadata.tiles(k);
        rgb=imread(tile.file);
        assert(isequal(size(rgb),[256 256 3]),'data1020:InvalidTile', ...
            'Expected a 256x256 RGB imagery tile: %s',tile.file);
        assert(double(max(rgb(:)))-double(min(rgb(:)))>5,'data1020:BlankTile', ...
            'Unexpected blank satellite tile: %s',tile.file);
        rows=(tile.y-metadata.yMin)*256+(1:256);
        columns=(tile.x-metadata.xMin)*256+(1:256);
        mosaic(rows,columns,:)=rgb;
    end
    earthRadius=6378137; halfWorld=pi*earthRadius;
    tileWidth=2*halfWorld/(2^metadata.zoom); pixelWidth=tileWidth/256;
    imageX=[-halfWorld+metadata.xMin*tileWidth+pixelWidth/2, ...
        -halfWorld+(metadata.xMax+1)*tileWidth-pixelWidth/2];
    imageY=[halfWorld-metadata.yMin*tileWidth-pixelWidth/2, ...
        halfWorld-(metadata.yMax+1)*tileWidth+pixelWidth/2];
end

function value = localText(s,field)
    value='';
    if isfield(s,field) && ~isempty(s.(field)), value=char(s.(field)); end
end
function x=localX(lon), x=6378137*deg2rad(lon); end
function y=localY(lat), y=6378137*asinh(tan(deg2rad(lat))); end
function lon=localLongitude(x), lon=rad2deg(x/6378137); end
function lat=localLatitude(y), lat=rad2deg(atan(sinh(y/6378137))); end
function localJson(path,value)
    fid=fopen(path,'w','n','UTF-8');
    assert(fid>0,'data1020:MapMetadata','Cannot write %s',path);
    cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
    fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
