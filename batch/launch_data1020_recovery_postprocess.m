% All receiver stages have finished; regenerate paired maps and comparisons.
cd('F:/matlab-GNSSsdr/BDS/B2a'); setupPaths;
root='F:/matlab-GNSSsdr/BDS/B2a/results/data1020/20261009_pb_tf_comparison';
manifestPath=fullfile(root,'manifest.json');
set(groot,'defaultFigureVisible','off'); maxNumCompThreads(1);
assert(isempty(gcp('nocreate')),'Postprocessing must run without a pool.');
assert(isfile(fullfile(root,'tf_full_completion.json')));

% Regenerate ALL PB/TF navigation displays with identical plotting rules.
% Load only the bounded navigation/settings payload, release it after each
% run, and let the helper own one explicitly invisible figure at a time.
% Numerical MAT files and the comparison algorithm are not changed here.
manifest=jsondecode(fileread(manifestPath));
assert(numel(manifest.entries)==6,'Expected six PB/TF experiment pairs.');
analysisDir=char(manifest.analysisDir);
if ~isfolder(analysisDir), mkdir(analysisDir); end
navigationAuditPath=fullfile(analysisDir,'navigation_figure_verification.json');
navigationAudit=struct('ok',false,'expectedRuns',12,'completedRuns',0, ...
    'sourceCheck','File size and modification timestamp before/after each export', ...
    'displayDefinition','Common offline navigation helper for every PB and TF run', ...
    'llaFinalization','Offline previews are subsequently replaced by export_data1020_satellite_maps', ...
    'records',struct([]));
localWriteNavigationAudit(navigationAuditPath,navigationAudit);
methods={'PB','TF'};
for experimentIndex=1:numel(manifest.entries)
    entry=manifest.entries(experimentIndex);
    for methodIndex=1:numel(methods)
        method=methods{methodIndex};
        if strcmp(method,'PB'), runDir=char(entry.pbDir); else, runDir=char(entry.tfDir); end
        sourcePath=fullfile(runDir,'ui_results.mat');
        assert(isfile(sourcePath),'data1020:NavigationUiMissing','Missing %s',sourcePath);
        before=dir(sourcePath);
        payload=load(sourcePath,'settings','navSolutions');
        assert(all(isfield(payload,{'settings','navSolutions'})), ...
            'data1020:NavigationUiFields','UI payload lacks settings/navSolutions: %s',sourcePath);
        fprintf('Navigation display %02d %s: %s\n',entry.experimentNumber,method,runDir);
        navReport=export_data1020_navigation_figures(payload.navSolutions,payload.settings, ...
            fullfile(runDir,'figures','navResult'));
        clear payload;
        assert(navReport.ok && numel(navReport.figureFiles)==5, ...
            'data1020:NavigationFiguresIncomplete','Expected five navigation figures for %02d %s.', ...
            entry.experimentNumber,method);
        after=dir(sourcePath);
        unchanged=isscalar(after) && before.bytes==after.bytes && before.datenum==after.datenum;
        assert(unchanged,'data1020:NavigationUiModified','Source UI MAT changed: %s',sourcePath);
        record=struct('experimentNumber',entry.experimentNumber,'method',method, ...
            'runDir',runDir,'sourceMat',sourcePath,'sourceBytes',before.bytes, ...
            'sourceDatenum',before.datenum,'sourceAfterBytes',after.bytes, ...
            'sourceAfterDatenum',after.datenum,'sourceUnchanged',unchanged,'figureAudit',navReport);
        if isempty(navigationAudit.records)
            navigationAudit.records=record;
        else
            navigationAudit.records(end+1)=record;
        end
        navigationAudit.completedRuns=numel(navigationAudit.records);
        localWriteNavigationAudit(navigationAuditPath,navigationAudit);
        clear navReport record before after;
    end
end
navigationAudit.ok=navigationAudit.completedRuns==navigationAudit.expectedRuns;
assert(navigationAudit.ok,'data1020:NavigationAuditIncomplete','Expected 12 navigation display records.');
localWriteNavigationAudit(navigationAuditPath,navigationAudit);
clear navigationAudit entry manifest;

% This MUST remain after the offline navigation loop: it replaces every
% temporary lla_geobasemap.png with the final satellite imagery / DME map.
export_data1020_satellite_maps(manifestPath);
compare_data1020_pb_tf(manifestPath);

function localWriteNavigationAudit(path,value)
    fid=fopen(path,'w','n','UTF-8'); assert(fid>0,'Cannot write %s',path);
    cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
    fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
