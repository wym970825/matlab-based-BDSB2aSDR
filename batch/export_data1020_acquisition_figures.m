function records = export_data1020_acquisition_figures(manifestPath, methods)
%EXPORT_DATA1020_ACQUISITION_FIGURES Replot saved acquisition; never rerun it.
% records = export_data1020_acquisition_figures(manifestPath)
% records = export_data1020_acquisition_figures(manifestPath,{'PB','TF'})
% Default: completed TF runs only. Every searched PRN is shown. The existing
% acquisition_metrics.png is replaced with an exact 1800-by-1000-pixel image.
% Figures remain invisible and are closed after each export. No pool starts.

    if nargin<2, methods={'TF'}; end
    methods=cellstr(upper(string(methods)));
    assert(all(ismember(methods,{'PB','TF'})),'data1020:AcquisitionMethods', ...
        'Methods must contain PB and/or TF.');
    methods=unique(methods,'stable');
    projectRoot=fileparts(fileparts(mfilename('fullpath')));
    addpath(projectRoot); setupPaths;
    manifest=jsondecode(fileread(char(manifestPath)));
    oldVisibility=get(groot,'defaultFigureVisible');
    set(groot,'defaultFigureVisible','off');
    visibilityCleanup=onCleanup(@() set(groot,'defaultFigureVisible',oldVisibility)); %#ok<NASGU>
    records=struct([]);
    for k=1:numel(manifest.entries)
        entry=manifest.entries(k);
        for methodIndex=1:numel(methods)
            method=methods{methodIndex}; field=[lower(method) 'Dir'];
            if ~isfield(entry,field) || isempty(entry.(field)), continue; end
            runDir=char(entry.(field));
            source=fullfile(runDir,'ui_results.mat');
            validationPath=fullfile(runDir,'validation.json');
            if ~isfile(source) || ~isfile(validationPath), continue; end
            validation=jsondecode(fileread(validationPath));
            if ~isfield(validation,'pipelineOk') || ~validation.pipelineOk, continue; end
            sourceBefore=dir(source);
            saved=load(source,'settings','results');
            assert(isfield(saved.results,'acqResults'), ...
                'data1020:MissingAcquisition','Missing acquisition results: %s',source);
            acq=saved.results.acqResults; prns=saved.settings.acqSatelliteList(:).';
            assert(numel(acq.peakMetric)==numel(prns) && numel(acq.peakMetric2)==numel(prns), ...
                'data1020:AcquisitionLength','Metrics and searched PRN list differ: %s',source);
            detected=acquisitionDetectedMask(acq);
            previousFigures=findall(groot,'Type','figure');
            figureCleanup=onCleanup(@() localCloseNewFigures(previousFigures));
            plotAcquisition(acq,prns);
            fig=gcf;
            set(fig,'Visible','off','Units','pixels','Position',[20 20 1800 1000], ...
                'Color','w','PaperUnits','inches','PaperPosition',[0 0 18 10], ...
                'PaperSize',[18 10],'PaperPositionMode','manual');
            axesList=findall(fig,'Type','axes');
            set(axesList,'FontSize',10,'XTickLabelRotation',90);
            set(findall(fig,'Type','legend'),'FontSize',11);
            for axisIndex=1:numel(axesList)
                assert(numel(axesList(axisIndex).XTick)==numel(prns), ...
                    'data1020:AcquisitionTicks','An acquisition panel omitted PRN labels.');
            end
            outDir=fullfile(runDir,'figures','AcqResult');
            if ~isfolder(outDir), mkdir(outDir); end
            pngPath=fullfile(outDir,'acquisition_metrics.png');
            drawnow;
            print(fig,pngPath,'-dpng','-r100');
            imageInfo=imfinfo(pngPath);
            assert(imageInfo.Width==1800 && imageInfo.Height==1000, ...
                'data1020:AcquisitionImageSize','Expected an exact 1800-by-1000 PNG.');
            sourceAfter=dir(source);
            assert(sourceBefore.bytes==sourceAfter.bytes && sourceBefore.datenum==sourceAfter.datenum, ...
                'data1020:AcquisitionSourceChanged','Saved receiver result changed during export.');
            row=struct('experimentNumber',entry.experimentNumber,'sourceId',entry.sourceId, ...
                'method',method,'sourceMat',source,'png',pngPath,'searchedPrns',prns, ...
                'detectedPrns',prns(detected),'panelCount',numel(axesList), ...
                'widthPixels',imageInfo.Width,'heightPixels',imageInfo.Height, ...
                'axisFontPt',10,'legendFontPt',11,'prnLabelRotationDeg',90, ...
                'receiverRerun',false,'sourceMatUnchanged',true);
            if isempty(records), records=row; else, records(end+1)=row; end %#ok<AGROW>
            fprintf('Acquisition image %02d %s: %d PRNs, %d acquired, %dx%d pixels\n', ...
                entry.experimentNumber,method,numel(prns),nnz(detected),imageInfo.Width,imageInfo.Height);
            clear figureCleanup fig saved acq;
        end
    end
    if isfield(manifest,'analysisDir') && ~isempty(manifest.analysisDir)
        auditDir=char(manifest.analysisDir);
    else
        auditDir=fullfile(char(manifest.outputRoot),'analysis');
    end
    if ~isfolder(auditDir), mkdir(auditDir); end
    outputPath=fullfile(auditDir,'acquisition_figure_verification.json');
    fid=fopen(outputPath,'w','n','UTF-8');
    assert(fid>0,'data1020:AcquisitionAudit','Cannot write %s',outputPath);
    cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
    fprintf(fid,'%s\n',jsonencode(records,'PrettyPrint',true));
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
