function report = export_data1020_navigation_figures(navSolutions, settings, saveDir)
%EXPORT_DATA1020_NAVIGATION_FIGURES Sequential, invisible, offline PVT plots.
%   report = export_data1020_navigation_figures(navSolutions,settings,saveDir)
%   accepts the navigation/settings fields loaded from an existing
%   ui_results.mat, or the identical in-memory navigation result. It writes
%   only PNGs and navigation_figure_verification.json; it never modifies or
%   saves navigation data, re-solves PVT, opens a browser, or starts workers.
%
% This presentation-only duplication of plotNavPost is intentional: the
% receiver source remains unchanged during recovery. navTrackTimeOrder,
% its epoch order / ENU jump filter, ENU reference and finite-difference
% velocity definitions are preserved. Each figure explicitly has Visible
% off and is closed before the next is constructed, including on errors.
%
% Sky geometry uses the original 90*cos(elevation) projection. Rows are
% ORIGINAL CHANNEL SLOTS, not PRN numbers or a compressed satellite list.
% PRN identity is checked across every epoch in each slot; trailing unused
% PRN rows may be absent because postNavigation assigns this field lazily.
% Finite geometry is paired with the PRN at the SAME slot and epoch. Labels
% use each satellite's last valid point, not an arbitrary first/last column.
% Below-horizon / above-zenith points are omitted only from the sky figure
% and counted in the audit. The original navigation arrays stay unchanged.
%
% lla_geobasemap.png is deliberately an explicitly labelled OFFLINE preview
% with no basemap. export_data1020_satellite_maps subsequently replaces it
% with the cached satellite imagery / DME station map required for delivery.

    saveDir=char(saveDir);
    assert(~isempty(saveDir),'data1020:NavigationSaveDir','A save directory is required.');
    if ~isfolder(saveDir), mkdir(saveDir); end
    report=struct('ok',false,'saveDir',saveDir,'figureFiles',{{}},'figureOutputs',struct([]), ...
        'visible',false,'maxSimultaneousFigures',1,'onlineBasemap',false, ...
        'navigationDataModified',false,'navigationRecomputed',false, ...
        'sourceDefinition','plotNavPost + navTrackTimeOrder', ...
        'timeDefinition','Original epoch index times navSolPeriod / 1000; no UTC resampling', ...
        'llaPreviewNote','Offline preview only; final cached satellite / DME map replaces this PNG', ...
        'skippedReason','');
    auditPath=fullfile(saveDir,'navigation_figure_verification.json');
    if isfield(settings,'plotNavPost') && ~isempty(settings.plotNavPost) && ~settings.plotNavPost
        report.ok=true; report.skippedReason='settings.plotNavPost is false';
        localJson(auditPath,report); return;
    end
    if isempty(navSolutions) || ~isfield(navSolutions,'latitude') || isempty(navSolutions.latitude)
        report.ok=true; report.skippedReason='No navigation latitude data';
        localJson(auditPath,report); return;
    end
    trk=navTrackTimeOrder(navSolutions,settings);
    report.retainedEpochIndices=trk.idx(:).';
    report.retainedFixes=trk.n;
    report.removedJumpFixes=trk.nRemovedJump;
    report.jumpThresholdComponentMps=trk.maxSpeedMps;
    if trk.n<1
        report.ok=true; report.skippedReason='No valid track after existing display filter';
        localJson(auditPath,report); return;
    end
    [refE,refN,refU,refLabel]=localEnuReference(trk,settings);
    report.enuReference=struct('E',refE,'N',refN,'U',refU,'label',refLabel);
    [sky,skyAudit]=localSkyData(navSolutions);
    report.sky=skyAudit;
    kinds={'enu','velocity','dop','sky','lla'};
    names={'enu_displacement.png','enu_velocity.png','dop.png','sky_plot.png','lla_geobasemap.png'};
    for k=1:numel(kinds)
        file=fullfile(saveDir,names{k});
        localRender(kinds{k},file,trk,refE,refN,refU,refLabel,sky);
        report.figureFiles{end+1}=file; %#ok<AGROW>
        info=imfinfo(file);
        output=struct('path',file,'fileName',names{k},'width',info.Width,'height',info.Height, ...
            'renderStage','offline_navigation', ...
            'subsequentlyReplacedBySatelliteMap',strcmp(kinds{k},'lla'));
        if isempty(report.figureOutputs)
            report.figureOutputs=output;
        else
            report.figureOutputs(end+1)=output;
        end
    end
    report.ok=true;
    localJson(auditPath,report);
end

function localRender(kind,file,trk,refE,refN,refU,refLabel,sky)
    % Own exactly one figure. No figure(handle), gcf/gca, or implicit axes.
    width=1400; height=950;
    if strcmp(kind,'sky'), width=1000; height=1000; end
    fig=figure('Visible','off','Color','w','NumberTitle','off', ...
        'MenuBar','none','ToolBar','none','Position',[1 1 width height]);
    cleanup=onCleanup(@() localClose(fig)); %#ok<NASGU>
    t=trk.t(:); dE=trk.E-refE; dN=trk.N-refN; dU=trk.U-refU;
    switch kind
        case {'enu','velocity'}
            tl=tiledlayout(fig,3,1,'TileSpacing','compact','Padding','compact');
            if strcmp(kind,'enu')
                tx=t; values={dE,dN,dU};
                labels={'\Delta E (m)','\Delta N (m)','\Delta U (m)'};
                heading=sprintf('ENU displacement  (ref: %s)  N=%d',refLabel,trk.n);
                timeLabel=sprintf('Time (s), navSolPeriod = %g ms',trk.navSolPeriodMs);
            else
                [vE,vN,vU,tx]=localEnuVelocity(t,dE,dN,dU);
                values={vE,vN,vU}; labels={'v_E (m/s)','v_N (m/s)','v_U (m/s)'};
                heading=sprintf('ENU velocity  N=%d intervals',numel(tx));
                timeLabel='Time (s)';
            end
            colors={'b','g','r'};
            for k=1:3
                ax=nexttile(tl,k);
                plot(ax,tx,values{k},[colors{k} '.-'],'MarkerSize',8);
                grid(ax,'on'); ylabel(ax,labels{k}); ax.FontSize=11;
                if k==1, title(ax,heading); end
            end
            xlabel(tl,timeLabel);
        case 'dop'
            ax=axes('Parent',fig); hold(ax,'on'); grid(ax,'on');
            fields={'GDOP','HDOP','VDOP','PDOP'};
            colors={[0 0 0],[0 0 1],[1 0 0],[0.5 0.5 0.5]};
            hasDop=false;
            for k=1:numel(fields)
                values=trk.(fields{k});
                if ~any(isfinite(values)), continue; end
                style='-'; marker='.';
                if k==4, style='--'; marker='none'; end
                plot(ax,t,values,'Color',colors{k},'LineStyle',style,'Marker',marker, ...
                    'DisplayName',fields{k}); hasDop=true;
            end
            if hasDop
                legend(ax,'Location','best'); ylabel(ax,'DOP');
                title(ax,sprintf('GDOP / HDOP / VDOP  (median GDOP=%.2f HDOP=%.2f VDOP=%.2f)', ...
                    localMed(trk.GDOP),localMed(trk.HDOP),localMed(trk.VDOP)));
            else
                text(ax,0.5,0.5,'No DOP data','Units','normalized','HorizontalAlignment','center');
                axis(ax,'off');
            end
            xlabel(ax,'Time (s)'); ax.FontSize=11;
        case 'sky'
            ax=axes('Parent',fig); localSkyPlot(ax,sky);
            title(ax,sprintf('Sky plot (median PDOP: %.2f)',localMed(trk.PDOP)));
        case 'lla'
            ax=axes('Parent',fig); hold(ax,'on');
            normalizedTime=t-t(1);
            if t(end)>t(1), normalizedTime=normalizedTime/(t(end)-t(1)); end
            if trk.n>=2
                plot(ax,trk.lon,trk.lat,'-','Color',[0.4 0.4 0.45], ...
                    'LineWidth',1.2,'DisplayName','track');
            end
            scatter(ax,trk.lon,trk.lat,28,normalizedTime,'filled', ...
                'MarkerFaceAlpha',0.85,'DisplayName','time');
            plot(ax,trk.lon(1),trk.lat(1),'o','MarkerSize',10, ...
                'MarkerFaceColor',[0.15 0.75 0.25],'MarkerEdgeColor','k','DisplayName','start');
            plot(ax,trk.lon(end),trk.lat(end),'s','MarkerSize',10, ...
                'MarkerFaceColor',[0.9 0.2 0.15],'MarkerEdgeColor','k','DisplayName','end');
            colormap(ax,data1020_purple_orange()); clim(ax,[0 1]);
            cb=colorbar(ax); cb.Label.String='Normalised time';
            grid(ax,'on'); axis(ax,'equal');
            xlabel(ax,'Longitude (deg, WGS84)'); ylabel(ax,'Latitude (deg, WGS84)');
            title(ax,{sprintf('PVT track  N=%d  mean (%.5f, %.5f)',trk.n,trk.meanLat,trk.meanLon), ...
                'Offline preview; satellite / DME map is exported separately'});
            legend(ax,'Location','best'); ax.FontSize=11;
    end
    assert(strcmp(get(fig,'Visible'),'off'),'data1020:NavigationFigureVisible', ...
        'Navigation export must remain invisible.');
    set(fig,'PaperUnits','inches','PaperPosition',[0 0 width/100 height/100], ...
        'PaperSize',[width/100 height/100],'PaperPositionMode','manual');
    print(fig,file,'-dpng','-r100');
    assert(isfile(file),'data1020:NavigationPng','Failed to write %s',file);
end

function [sky,audit]=localSkyData(nav)
    sky=struct('slot',{},'PRN',{},'az',{},'el',{});
    audit=struct('mapping','PRN / az / el are paired by original channel slot and epoch', ...
        'projection','radius = 90*cos(elevation in degrees)', ...
        'sourceEpochSelection','All saved sky epochs, as in plotNavPost; independent of PVT track display filter', ...
        'omittedOutsideVisibleHemisphere',0,'slotRecords',struct([]),'missingFields',false);
    if ~all(isfield(nav,{'PRN','az','el'})) || isempty(nav.az) || isempty(nav.el)
        audit.missingFields=true; return;
    end
    az=double(nav.az); el=double(nav.el); prn=double(nav.PRN);
    assert(ismatrix(az) && isequal(size(az),size(el)) && ismatrix(prn), ...
        'data1020:SkyDimensions','Sky az/el must have identical channel-slot by epoch dimensions.');
    assert(size(prn,1)<=size(az,1) && size(prn,2)<=size(az,2), ...
        'data1020:SkyPrnDimensions','PRN dimensions cannot exceed az/el dimensions.');
    % postNavigation lazily expands PRN only to the last active slot.
    identities=zeros(size(az));
    identities(1:size(prn,1),1:size(prn,2))=prn;
    validIdentity=isfinite(identities) & identities>=1 & identities<=63 & identities==fix(identities);
    geometry=isfinite(az)&isfinite(el);
    assert(~any(geometry(:)&~validIdentity(:)), ...
        'data1020:SkyUnlabelledGeometry','Finite sky geometry has no valid PRN at the same slot and epoch.');
    records=struct([]); seen=[];
    for slot=1:size(az,1)
        ids=unique(identities(slot,validIdentity(slot,:)));
        assert(numel(ids)<=1,'data1020:SkySlotIdentity','Channel slot %d changes PRN identity.',slot);
        if isempty(ids), continue; end
        id=ids(1);
        assert(~ismember(id,seen),'data1020:SkyDuplicatePrn','PRN %d occupies multiple channel slots.',id);
        seen(end+1)=id; %#ok<AGROW>
        paired=geometry(slot,:) & identities(slot,:)==id;
        above=paired & el(slot,:)>=0 & el(slot,:)<=90;
        nOutside=nnz(paired & ~above);
        audit.omittedOutsideVisibleHemisphere=audit.omittedOutsideVisibleHemisphere+nOutside;
        columns=find(above);
        row=struct('slot',slot,'PRN',id,'finitePairedPoints',nnz(paired), ...
            'displayedPoints',nnz(above),'outsideVisibleHemisphere',nOutside, ...
            'firstDisplayedEpoch',[],'lastDisplayedEpoch',[]);
        if ~isempty(columns)
            row.firstDisplayedEpoch=columns(1); row.lastDisplayedEpoch=columns(end);
            a=az(slot,:); e=el(slot,:); a(~above)=NaN; e(~above)=NaN;
            sky(end+1)=struct('slot',slot,'PRN',id,'az',a,'el',e); %#ok<AGROW>
        end
        if isempty(records), records=row; else, records(end+1)=row; end %#ok<AGROW>
    end
    audit.slotRecords=records;
end

function localSkyPlot(ax,sky)
    hold(ax,'on'); axis(ax,'equal'); axis(ax,'off');
    xlim(ax,[-108 108]); ylim(ax,[-108 112]);
    theta=linspace(0,2*pi,181);
    for elevation=0:15:90
        radius=90*cosd(elevation);
        plot(ax,radius*sin(theta),radius*cos(theta),':','Color',[0.65 0.65 0.65], ...
            'HandleVisibility','off');
        labelX=0; labelAlignment='center';
        if elevation==0
            % The cosine projection places the 0/15-degree rings close
            % together. Move only the horizon text clear of the 15-degree
            % label's white background; do not alter grid/data geometry.
            labelX=-12; labelAlignment='right';
        end
        text(ax,labelX,radius,[num2str(elevation) '\circ'],'BackgroundColor','w', ...
            'HorizontalAlignment',labelAlignment,'FontSize',9);
    end
    for azimuth=0:30:330
        plot(ax,[0 90*sind(azimuth)],[0 90*cosd(azimuth)],':', ...
            'Color',[0.65 0.65 0.65],'HandleVisibility','off');
        text(ax,101*sind(azimuth),101*cosd(azimuth),sprintf('%d',azimuth), ...
            'HorizontalAlignment','center','VerticalAlignment','middle','FontSize',10);
    end
    if isempty(sky)
        text(ax,0,-105,'No labelled above-horizon az/el data','HorizontalAlignment','center');
        return;
    end
    colors=lines(numel(sky));
    for k=1:numel(sky)
        radius=90*cosd(sky(k).el);
        x=radius.*sind(sky(k).az); y=radius.*cosd(sky(k).az);
        plot(ax,x,y,'.-','Color',colors(k,:),'LineWidth',1.2,'MarkerSize',5);
        last=find(isfinite(x)&isfinite(y),1,'last');
        plot(ax,x(last),y(last),'o','Color',colors(k,:),'MarkerFaceColor','w','MarkerSize',7);
        text(ax,x(last),y(last),sprintf('  C%02d',sky(k).PRN), ...
            'Color',colors(k,:),'FontSize',11,'FontWeight','bold');
    end
end

function [refE, refN, refU, label] = localEnuReference(trk, settings)
    te = localScalarOrNan(settings, 'truePosition', 'E');
    tn = localScalarOrNan(settings, 'truePosition', 'N');
    tu = localScalarOrNan(settings, 'truePosition', 'U');
    if isfinite(te) && isfinite(tn) && isfinite(tu)
        refE = te; refN = tn; refU = tu; label = 'truePosition';
    else
        refE = mean(trk.E(isfinite(trk.E)));
        refN = mean(trk.N(isfinite(trk.N)));
        refU = mean(trk.U(isfinite(trk.U)));
        if ~isfinite(refE), refE = 0; end
        if ~isfinite(refN), refN = 0; end
        if ~isfinite(refU), refU = 0; end
        label = 'mean ENU';
    end
end
function v = localScalarOrNan(settings, parent, field)
    v = nan;
    if ~isstruct(settings) || ~isfield(settings, parent), return; end
    s = settings.(parent);
    if ~isstruct(s) || ~isfield(s, field), return; end
    x = s.(field);
    if isnumeric(x) && isscalar(x), v = double(x); end
end
function [vE, vN, vU, tMid] = localEnuVelocity(t, dE, dN, dU)
    t = t(:); dE = dE(:); dN = dN(:); dU = dU(:);
    if numel(t) < 2
        vE = []; vN = []; vU = []; tMid = []; return;
    end
    dt = diff(t); dt(dt <= 0) = NaN;
    vE = diff(dE) ./ dt; vN = diff(dN) ./ dt; vU = diff(dU) ./ dt;
    tMid = t(1:end-1) + dt / 2;
    ok = isfinite(vE) & isfinite(vN) & isfinite(tMid);
    vE = vE(ok); vN = vN(ok); vU = vU(ok); tMid = tMid(ok);
end
function m = localMed(x)
    x = x(isfinite(x));
    if isempty(x), m = NaN; else, m = median(x); end
end
function localClose(fig)
    if isgraphics(fig), close(fig); end
end
function localJson(path,value)
    fid=fopen(path,'w','n','UTF-8'); assert(fid>0,'Cannot write %s',path);
    cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
    fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
