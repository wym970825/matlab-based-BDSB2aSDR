function report = finalize_data1020_saved_run(manifestPath, experimentIndex)
%FINALIZE_DATA1020_SAVED_RUN Finish an interrupted run using complete finals.
% Recovery state is supplied separately in <tfDir>/recovery_state.mat with
% settings, acqResults and channel. The original 63-slot preRun2 order stays
% unchanged. This function does not acquire or track any satellite and does
% not modify the numerical receiver or any Trk_Prn_*_final.mat input.
%
% Some reused channel entries retain their initial acquisition metadata:
% full post-REACQ chOut state was never checkpointed. Their status is restored
% from finalTRes. Navigation reads complete trackResults, not channel metadata.
% The caller performs the normal pair audit and writes validation/summary CSVs.

    projectRoot=fileparts(fileparts(mfilename('fullpath')));
    addpath(projectRoot); setupPaths;
    manifest=jsondecode(fileread(char(manifestPath)));
    validateattributes(experimentIndex,{'numeric'},{'scalar','integer','positive'});
    assert(experimentIndex<=numel(manifest.entries),'data1020:RecoveryIndex','Invalid experiment index.');
    entry=manifest.entries(experimentIndex); outDir=char(entry.tfDir);
    statePath=fullfile(outDir,'recovery_state.mat');
    assert(isfile(statePath),'data1020:RecoveryState','Missing %s',statePath);
    state=load(statePath,'settings','acqResults','channel');
    assert(all(isfield(state,{'settings','acqResults','channel'})), ...
        'data1020:RecoveryState','Recovery state lacks required variables.');
    settings=state.settings; acqResults=state.acqResults; channel=state.channel; clear state;
    assert(isstruct(settings) && isscalar(settings) && isstruct(channel), ...
        'data1020:RecoveryState','Invalid settings/channel types.');
    assert(strcmp(settings.Frontend.mode,'tf_v1'),'data1020:RecoveryFrontend','Expected TF v1 results.');
    tempDir=fullfile(outDir,'temp');
    assert(localSamePath(settings.resultRoot,outDir) && localSamePath(settings.tempdataSvPth,tempDir), ...
        'data1020:RecoveryPaths','Recovery settings must point at the original TF run/temp folders.');
    nCh=double(settings.numberOfChannels);
    assert(nCh==63 && numel(channel)==nCh,'data1020:RecoverySlots', ...
        'Preserve the original 63 tracking/channel slots.');
    activeIdx=find([channel.PRN]>0); channelPrns=double([channel(activeIdx).PRN]);
    detected=acquisitionDetectedMask(acqResults);
    searched=double(settings.acqSatelliteList(:).');
    assert(numel(detected)==numel(searched),'data1020:RecoveryAcquisition','PRN/acquisition length mismatch.');
    acquiredPrns=searched(detected);
    assert(numel(unique(channelPrns))==numel(channelPrns) ...
        && isequal(sort(channelPrns(:)),sort(acquiredPrns(:))), ...
        'data1020:RecoveryChannelMatch','Channel and acquired PRN sets differ.');
    files=dir(fullfile(tempDir,'Trk_Prn_*_final.mat'));
    finalPrns=zeros(1,numel(files));
    for k=1:numel(files)
        token=regexp(files(k).name,'^Trk_Prn_(\d+)_final\.mat$','tokens','once');
        assert(~isempty(token),'data1020:RecoveryFilename','Unexpected final filename: %s',files(k).name);
        finalPrns(k)=str2double(token{1});
    end
    assert(numel(unique(finalPrns))==numel(finalPrns) ...
        && isequal(sort(finalPrns(:)),sort(acquiredPrns(:))), ...
        'data1020:RecoveryFinalSet','All and only acquired PRNs must have complete final MAT files.');

    figDir=fullfile(outDir,'figures'); acqFigDir=fullfile(figDir,'AcqResult');
    trkFigDir=fullfile(figDir,'trkResult'); navFigDir=fullfile(figDir,'navResult');
    for folder={figDir,acqFigDir,trkFigDir,navFigDir}
        if ~isfolder(folder{1}), mkdir(folder{1}); end
    end
    oldVisibility=get(groot,'defaultFigureVisible');
    set(groot,'defaultFigureVisible','off');
    visibilityCleanup=onCleanup(@() set(groot,'defaultFigureVisible',oldVisibility)); %#ok<NASGU>
    previousFigures=findall(groot,'Type','figure');
    figureCleanup=onCleanup(@() localCloseNewFigures(previousFigures)); %#ok<NASGU>
    tag=char(settings.tag);
    report=struct('ok',false,'outDir',outDir,'figDir',figDir,'acqFigDir',acqFigDir, ...
        'trkFigDir',trkFigDir,'navFigDir',navFigDir,'tag',tag,'frontend',settings.Frontend, ...
        'softwareVersion',strtrim(fileread(fullfile(projectRoot,'VERSION'))), ...
        'stage','loading_saved_tracking','errorIdentifier','','error','','nmeaPath','', ...
        'nAcquired',numel(acquiredPrns),'requestedMs',settings.msToProcess, ...
        'effectiveMs',settings.msToProcess,'navSummary', ...
        struct('nFixes',0,'meanLat',NaN,'meanLon',NaN,'meanH',NaN));
    report.recovery=struct('statePath',statePath,'experimentNumber',entry.experimentNumber, ...
        'acquisitionRunByFinalizer',false,'trackingRunByFinalizer',false, ...
        'sourceTrackingPrns',finalPrns,'channelSlots',nCh, ...
        'channelPrnOrder',channelPrns, ...
        'channelMetadataNote',['Reused slots may retain initial acquisition metadata because their ' ...
        'post-REACQ chOut was not checkpointed; status is restored from finalTRes. ' ...
        'Navigation consumes saved trackResults in original slot order, not channel metadata.']);
    reportPath=fullfile(outDir,'report.json');
    localJson(reportPath,report); started=tic;
    navSolutions=[]; eph=[];
    try
        trackResults=TrackResults2.createEmptyArray(nCh);
        sourceSnapshots=struct([]);
        for slot=reshape(activeIdx,1,[])
            prn=double(channel(slot).PRN);
            source=fullfile(tempDir,sprintf('Trk_Prn_%02d_final.mat',prn));
            before=dir(source); loaded=load(source,'finalTRes');
            assert(isfield(loaded,'finalTRes') && isstruct(loaded.finalTRes) && isscalar(loaded.finalTRes), ...
                'data1020:RecoveryFinalType','Expected scalar finalTRes struct: %s',source);
            tr=loaded.finalTRes;
            assert(tr.PRN==prn && ~isempty(tr.I_P) && numel(tr.absoluteSample)==numel(tr.I_P), ...
                'data1020:RecoveryFinalIdentity','Invalid PRN or sample count in %s',source);
            assert(~isempty(tr.status) && char(tr.status(1))~='-', ...
                'data1020:RecoveryFinalStatus','Acquired PRN has an inactive saved status: %s',source);
            if isfield(tr,'frontendInfo') && isfield(tr.frontendInfo,'configHash')
                assert(strcmp(tr.frontendInfo.configHash,settings.Frontend.configHash), ...
                    'data1020:RecoveryFrontendMismatch','Saved frontend hash differs for PRN %d.',prn);
            end
            trackResults(slot)=TrackResults2.fromStruct(tr);
            channel(slot).status=char(tr.status);
            snapshot=struct('PRN',prn,'slot',slot,'path',source,'bytes',before.bytes,'datenum',before.datenum);
            if isempty(sourceSnapshots), sourceSnapshots=snapshot; else, sourceSnapshots(end+1)=snapshot; end %#ok<AGROW>
            clear loaded tr;
        end
        activeTracks=trackResults(activeIdx);
        report.trackingSummary=arrayfun(@(tr) struct('PRN',tr.PRN, ...
            'recordedMs',numel(tr.I_P),'finiteMs',nnz(isfinite(tr.I_P)&isfinite(tr.absoluteSample)), ...
            'reacqMs',nnz(tr.trk_state==9)),activeTracks);
        clear activeTracks;
        report.recovery.sourceFinals=sourceSnapshots;

        doPlot=localFlag(settings,'doPlot',true);
        if doPlot && localFlag(settings,'plotTracking',true)
            report.stage='tracking_plots'; localJson(reportPath,report);
            trackingReport=exportTrackingFiguresSequential(trackResults,settings,trkFigDir, ...
                'ChannelIndices',activeIdx,'Visible',false);
            assert(trackingReport.ok,'data1020:RecoveryTrackingPlot','Some tracking figures failed.');
            report.trackingFigures=trackingReport.figureFiles;
        end
        if localFlag(settings,'doNavigation',true)
            report.stage='navigation'; localJson(reportPath,report);
            [navSolutions,eph]=runNavigation(trackResults,settings);
            if localFlag(settings,'doNmea',true) && ~isempty(navSolutions)
                report.nmeaPath=exportNmea(navSolutions,settings, ...
                    'trackResults',trackResults,'eph',eph,'outDir',outDir);
                assert(~isempty(report.nmeaPath) && isfile(report.nmeaPath), ...
                    'data1020:RecoveryNmea','NMEA export did not produce a file.');
            end
        end
        if doPlot && ~isempty(navSolutions)
            report.stage='plot'; localJson(reportPath,report);
            navigationFigures=plotNavPost(navSolutions,settings, ...
                'saveDir',navFigDir,'doLegacy',false, ...
                'openBaiduMap',false,'openBaiduBrowser',false);
            localCloseFigureStruct(navigationFigures); clear navigationFigures;
            drawnow;
        end
        if ~isempty(navSolutions) && isfield(navSolutions,'latitude')
            valid=isfinite(navSolutions.latitude)&isfinite(navSolutions.longitude);
            report.navSummary.nFixes=nnz(valid);
            if any(valid)
                report.navSummary.meanLat=mean(navSolutions.latitude(valid));
                report.navSummary.meanLon=mean(navSolutions.longitude(valid));
                if isfield(navSolutions,'height')
                    heights=navSolutions.height(valid);
                    report.navSummary.meanH=mean(heights(isfinite(heights)));
                end
            end
        end

        report.stage='saving'; localJson(reportPath,report);
        % Build the bounded UI payload first. Avoid retaining a second full
        % tracking container while serializing the scientific archive.
        results=struct('settings',settings,'acqResults',acqResults,'channel',channel, ...
            'trackResults',[],'navSolutions',navSolutions,'eph',eph);
        writeUiResultsMat(fullfile(outDir,'ui_results.mat'),results);
        results.trackResults=trackResultsToStruct(trackResults);
        clear trackResults;
        fullPath=fullfile(outDir,sprintf('run_B2a_%s.mat',tag));
        save(fullPath,'results','-v7.3');
        clear results;
        for k=1:numel(sourceSnapshots)
            snapshot=sourceSnapshots(k); after=dir(snapshot.path);
            assert(isscalar(after) && after.bytes==snapshot.bytes && after.datenum==snapshot.datenum, ...
                'data1020:RecoverySourceModified','Input tracking final changed during finalization.');
        end
        report.recovery.sourceFinalsUnchanged=true;
        report.recovery.unchangedCheck='File size and modification timestamp';
        report.recovery.fullResultsPath=fullPath;
        report.recovery.finalizationSeconds=toc(started);
        report.ok=true; report.stage='done';
        localJson(reportPath,report);
        fprintf('Recovered experiment %02d finalized: %d PRNs, %d fixes, %.1f seconds\n', ...
            entry.experimentNumber,report.nAcquired,report.navSummary.nFixes,toc(started));
    catch ME
        report.ok=false; report.errorIdentifier=ME.identifier; report.error=ME.message;
        report.recovery.finalizationSeconds=toc(started);
        localJson(reportPath,report);
        rethrow(ME);
    end
end

function tf=localFlag(s,name,fallback)
    tf=fallback;
    if isfield(s,name) && ~isempty(s.(name)), tf=logical(s.(name)); end
end
function tf=localSamePath(a,b)
    a=regexprep(strrep(char(a),'\','/'),'/+$','');
    b=regexprep(strrep(char(b),'\','/'),'/+$','');
    tf=strcmpi(a,b);
end
function localJson(path,value)
    fid=fopen(path,'w','n','UTF-8'); assert(fid>0,'Cannot write %s',path);
    cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
    fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
function localCloseFigureStruct(figures)
    if ~isstruct(figures), return; end
    names=fieldnames(figures);
    for k=1:numel(names)
        handle=figures.(names{k});
        if ~isempty(handle) && all(isgraphics(handle)), close(handle); end
    end
end
function localCloseNewFigures(previousFigures)
    currentFigures=findall(groot,'Type','figure');
    for k=1:numel(currentFigures)
        current=currentFigures(k);
        if isgraphics(current) && (isempty(previousFigures) || ~any(current==previousFigures)), close(current); end
    end
end
