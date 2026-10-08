function records = export_data1020_tracking_figures(manifestPath, methods)
%EXPORT_DATA1020_TRACKING_FIGURES Correct units in saved PB/TF diagnostics.
% Only presentation changes: pllDiscr is phase error in cycles, whereas
% pllDiscrFilt stores carrier NCO in Hz. dllDiscr is a normalized E-L/E+L
% ratio, whereas dllDiscrFilt stores code NCO in chips/s. Each pair therefore
% uses separate labelled y axes, not one axis labelled "Raw / Filtered".
%
% The lightweight plotting structure intentionally duplicates parts of
% include/exportTrackingFiguresSequential.m to isolate this postprocessor
% from the running receiver. Do not modify the active receiver plot helper.
% Read one final MAT and render one invisible figure at a time; never rerun
% acquisition, tracking or navigation. All TF runs must already be complete.
% The original display time (row index - 1)*intTime is retained and explicitly
% labelled nominal tracking time; it is not physical IF-file time after REACQ.

    if nargin<2, methods={'PB','TF'}; end
    methods=unique(cellstr(upper(string(methods))),'stable');
    assert(all(ismember(methods,{'PB','TF'})),'data1020:TrackingMethods', ...
        'Methods must contain PB and/or TF.');
    manifest=jsondecode(fileread(char(manifestPath)));
    % Refuse to rewrite plots while any experiment is still running.
    for k=1:numel(manifest.entries)
        path=fullfile(char(manifest.entries(k).tfDir),'validation.json');
        assert(isfile(path),'data1020:TrackingFinalizationEarly', ...
            'All TF experiments must finish before tracking figures are finalized.');
        validation=jsondecode(fileread(path));
        assert(validation.pipelineOk,'data1020:TrackingFinalizationEarly', ...
            'A TF experiment is incomplete or failed: %s',path);
    end
    oldVisibility=get(groot,'defaultFigureVisible');
    set(groot,'defaultFigureVisible','off');
    visibilityCleanup=onCleanup(@() set(groot,'defaultFigureVisible',oldVisibility)); %#ok<NASGU>
    records=struct([]); maxPoints=20000;
    for k=1:numel(manifest.entries)
        entry=manifest.entries(k);
        for methodIndex=1:numel(methods)
            method=methods{methodIndex}; runDir=char(entry.([lower(method) 'Dir']));
            settingsPath=fullfile(runDir,'ui_results.mat'); settingsBefore=dir(settingsPath);
            saved=load(settingsPath,'settings'); settings=saved.settings; clear saved;
            dt=double(settings.intTime);
            assert(isfinite(dt) && dt>0,'data1020:TrackingTimeStep','Invalid integration time.');
            files=dir(fullfile(runDir,'temp','Trk_Prn_*_final.mat'));
            assert(~isempty(files),'data1020:TrackingFiles','No final tracking MAT files: %s',runDir);
            outDir=fullfile(runDir,'figures','trkResult');
            if ~isfolder(outDir), mkdir(outDir); end
            for fileIndex=1:numel(files)
                source=fullfile(files(fileIndex).folder,files(fileIndex).name);
                sourceBefore=dir(source);
                saved=load(source,'finalTRes');
                channel=saved.finalTRes; clear saved;
                if isobject(channel) && ismethod(channel,'toStruct'), channel=channel.toStruct(); end
                assert(isstruct(channel) && isscalar(channel),'data1020:TrackingSource', ...
                    'Expected one saved channel: %s',source);
                n=localValidLength(channel);
                prn=double(channel.PRN);
                previousFigures=findall(groot,'Type','figure');
                figureCleanup=onCleanup(@() localCloseNewFigures(previousFigures));
                fig=localFigure(channel,n,settings,entry,method,maxPoints);
                pngPath=fullfile(outDir,sprintf('PRN_%02d_tracking.png',prn));
                exportgraphics(fig,pngPath,'Resolution',140);
                imageInfo=imfinfo(pngPath);
                sourceAfter=dir(source);
                assert(localUnchanged(sourceBefore,sourceAfter), ...
                    'data1020:TrackingSourceChanged','Final tracking MAT changed during export: %s',source);
                row=struct('experimentNumber',entry.experimentNumber,'sourceId',entry.sourceId, ...
                    'method',method,'PRN',prn,'sourceMat',source,'png',pngPath, ...
                    'sourceBytes',sourceAfter.bytes,'sourceDatenum',sourceAfter.datenum, ...
                    'sourceMatUnchanged',true,'unchangedCheck','File size and modification timestamp', ...
                    'plottedNominalEpochs',n,'epochSeconds',dt, ...
                    'widthPixels',imageInfo.Width,'heightPixels',imageInfo.Height, ...
                    'nominalTimeRangeSeconds',[0 max(0,n-1)*dt], ...
                    'pllDiscrUnit','cycles','pllDiscrFiltMeaning','carrier NCO (Hz)', ...
                    'dllDiscrUnit','dimensionless normalized E-L/E+L', ...
                    'dllDiscrFiltMeaning','code NCO (chips/s)', ...
                    'reacqPlaceholderValuesPreserved',true, ...
                    'stateTransitionPointsPreserved',true,'maxUniformPlotPoints',maxPoints, ...
                    'receiverRerun',false,'rawStatisticsRecomputed',false);
                if isempty(records), records=row; else, records(end+1)=row; end %#ok<AGROW>
                fprintf('Tracking units corrected %02d %s PRN%02d: %d epochs\n', ...
                    entry.experimentNumber,method,prn,n);
                clear figureCleanup fig channel;
            end
            assert(localUnchanged(settingsBefore,dir(settingsPath)), ...
                'data1020:TrackingSettingsChanged','Saved settings changed during export.');
        end
    end
    audit=struct('allSourceMatsUnchanged',true,'receiverRerun',false, ...
        'originalPlotHelperUnmodified',true,'records',records, ...
        'timeAxisNote',['Original nominal row-index time retained; C/N0 uses nominal ' ...
        'CNoInterval display spacing. Neither is a remapping to physical IF time.'], ...
        'reacqNote',['REACQ correlator/discriminator/NCO zeros are stored placeholders, ' ...
        'preserved for consistency; they are not valid measurements of zero error. ' ...
        'The state panel retains all transition points.'], ...
        'phaseNote','PLL cycles are the stored Costas phase error, held between long-coherent updates.');
    auditDir=char(manifest.analysisDir); if ~isfolder(auditDir), mkdir(auditDir); end
    path=fullfile(auditDir,'tracking_figure_verification.json');
    fid=fopen(path,'w','n','UTF-8'); assert(fid>0,'Cannot write tracking-figure audit.');
    cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
    fprintf(fid,'%s\n',jsonencode(audit,'PrettyPrint',true));
end

function fig=localFigure(channel,n,settings,entry,method,maxPoints)
    fig=figure('Visible','off','Color','w','Position',[40 40 1800 1080], ...
        'Name',sprintf('PRN %02d tracking units corrected',channel.PRN),'NumberTitle','off');
    layout=tiledlayout(fig,3,3,'TileSpacing','compact','Padding','compact');
    dt=double(settings.intTime);
    cnoInterval=double(settings.CNoInterval);
    if isfield(channel,'CNoInterval') && isfinite(channel.CNoInterval) && channel.CNoInterval>0
        cnoInterval=double(channel.CNoInterval);
    end
    cnoLength=max(1,ceil(n/cnoInterval));

    ax=nexttile(layout);
    ip=localVector(channel,'I_P',n); qp=localVector(channel,'Q_P',n);
    nq=min(numel(ip),numel(qp)); ix=localIndices(nq,maxPoints);
    if ~isempty(ix), scatter(ax,ip(ix),qp(ix),4,'filled','MarkerFaceAlpha',.25); end
    grid(ax,'on'); axis(ax,'equal'); title(ax,'Prompt IQ'); xlabel(ax,'I'); ylabel(ax,'Q');

    ax=nexttile(layout);
    localTrace(ax,localPower(channel,'I_P','Q_P',n),dt,maxPoints,'Data');
    localTrace(ax,localPower(channel,'Pilot_I_P','Pilot_Q_P',n),dt,maxPoints,'Pilot');
    localFinish(ax,'Prompt power','Squared correlator magnitude',true);

    ax=nexttile(layout);
    localTrace(ax,localVector(channel,'DataCNo',cnoLength),dt*cnoInterval,maxPoints,'Data');
    localTrace(ax,localVector(channel,'PilotCNo',cnoLength),dt*cnoInterval,maxPoints,'Pilot');
    localTrace(ax,localVector(channel,'B2a_CNo',cnoLength),dt*cnoInterval,maxPoints,'B2a');
    localFinish(ax,'C/N0','dB-Hz',true);

    ax=nexttile(layout);
    localTrace(ax,localVector(channel,'carrFreq',n),dt,maxPoints,'Carrier');
    localFinish(ax,'Carrier wipe-off frequency (IF domain)','Hz',false);

    ax=nexttile(layout);
    localTrace(ax,localVector(channel,'codeFreq',n),dt,maxPoints,'Code');
    localFinish(ax,'Code rate','chips/s',false);

    ax=nexttile(layout);
    yyaxis(ax,'left');
    localTrace(ax,localVector(channel,'pllDiscr',n),dt,maxPoints,'Stored phase error');
    ylabel(ax,'Phase error (cycles)');
    yyaxis(ax,'right');
    localTrace(ax,localVector(channel,'pllDiscrFilt',n),dt,maxPoints,'Carrier NCO');
    ylabel(ax,'Carrier NCO (Hz)');
    localFinish(ax,'PLL phase error and carrier NCO','',true);
    yyaxis(ax,'left');

    ax=nexttile(layout);
    yyaxis(ax,'left');
    localTrace(ax,localVector(channel,'dllDiscr',n),dt,maxPoints,'Normalized DLL error');
    ylabel(ax,'Normalized (E-L)/(E+L), unitless');
    yyaxis(ax,'right');
    localTrace(ax,localVector(channel,'dllDiscrFilt',n),dt,maxPoints,'Code NCO');
    ylabel(ax,'Code NCO (chips/s)');
    localFinish(ax,'DLL discriminator and code NCO','',true);
    yyaxis(ax,'left');

    ax=nexttile(layout);
    fields={'fllDiscrHz','fllDiscrFiltHz','fllCorrHz','kf_corrHz'};
    labels={'FLL raw','FLL filtered','FLL correction','KF correction'};
    for k=1:numel(fields), localTrace(ax,localVector(channel,fields{k},n),dt,maxPoints,labels{k}); end
    localFinish(ax,'Frequency corrections','Hz',true);

    ax=nexttile(layout); state=localVector(channel,'trk_state',n);
    if isempty(state), state=localVector(channel,'cur_state',n); end
    localStairs(ax,state,dt,maxPoints,'State');
    localStairs(ax,localVector(channel,'fllAided',n),dt,maxPoints,'FLL aided');
    localFinish(ax,'Tracking state (9 = REACQ)','State / flag',true);
    sgtitle(layout,sprintf('Experiment %02d | %s | %s | PRN %02d | N=%d | nominal tracking-time axis', ...
        entry.experimentNumber,method,entry.sourceId,channel.PRN,n),'Interpreter','none');
end

function localTrace(ax,value,step,maxPoints,label)
    if isempty(value), return; end
    ix=localIndices(numel(value),maxPoints); hold(ax,'on');
    plot(ax,(ix-1)*step,value(ix),'LineWidth',.8,'DisplayName',label);
end
function localStairs(ax,value,step,maxPoints,label)
    if isempty(value), return; end
    ix=localIndices(numel(value),maxPoints);
    transitions=find(diff(value)~=0);
    ix=unique([ix transitions transitions+1]); hold(ax,'on');
    stairs(ax,(ix-1)*step,value(ix),'LineWidth',.8,'DisplayName',label);
end
function localFinish(ax,heading,unit,showLegend)
    grid(ax,'on'); title(ax,heading); xlabel(ax,'Nominal tracking time (s)');
    if ~isempty(unit), ylabel(ax,unit); end
    if isempty(findobj(ax,'-property','YData'))
        text(ax,.5,.5,'No saved data','Units','normalized','HorizontalAlignment','center');
    elseif showLegend
        legend(ax,'show','Location','best');
    end
end
function value=localVector(channel,name,n)
    value=[];
    if isfield(channel,name) && (isnumeric(channel.(name)) || islogical(channel.(name))) ...
            && isvector(channel.(name))
        raw=channel.(name); value=double(raw(:).'); value=value(1:min(n,numel(value)));
    end
end
function value=localPower(channel,iname,qname,n)
    i=localVector(channel,iname,n); q=localVector(channel,qname,n);
    count=min(numel(i),numel(q)); value=i(1:count).^2+q(1:count).^2;
end
function ix=localIndices(n,maxPoints)
    if n<=maxPoints, ix=1:n; else, ix=unique(round(linspace(1,n,maxPoints))); end
end
function n=localValidLength(channel)
    fields={'absoluteSample','I_P','codeFreq','remCodePhase'}; last=[];
    for k=1:numel(fields)
        if isfield(channel,fields{k})
            final=find(isfinite(channel.(fields{k})),1,'last');
            if ~isempty(final), last(end+1)=final; end %#ok<AGROW>
        end
    end
    assert(~isempty(last),'data1020:EmptyTracking','No finite recorded tracking epochs.');
    n=min(last);
end
function same=localUnchanged(before,after)
    same=isscalar(before) && isscalar(after) && before.bytes==after.bytes && before.datenum==after.datenum;
end
function localCloseNewFigures(previousFigures)
    currentFigures=findall(groot,'Type','figure');
    for k=1:numel(currentFigures)
        current=currentFigures(k);
        if isgraphics(current) && (isempty(previousFigures) || ~any(current==previousFigures))
            close(current);
        end
    end
end
