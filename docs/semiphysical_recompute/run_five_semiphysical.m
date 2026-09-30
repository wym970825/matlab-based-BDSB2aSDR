function batch = run_five_semiphysical(caseIndices, execute, outputRoot, options)
%RUN_FIVE_SEMIPHYSICAL Prepare or run the five saved laboratory RF configs.
% run_five_semiphysical()       prepares all cases; does NOT run the receiver.
% run_five_semiphysical(1,true) runs the DME-free case in a new output folder.
% run_five_semiphysical(1:5,true) runs all five sequentially; stops on failure.
arguments
    caseIndices (1,:) double = 1:5
    execute (1,1) logical = false
    outputRoot (1,1) string = ""
    options.ContinueOnFailure (1,1) logical = false
end
pkg=fileparts(mfilename('fullpath'));
manifest=jsondecode(fileread(fullfile(pkg,'five_cases.json')));
assert(~isempty(caseIndices) && all(ismember(caseIndices,1:5)) && ...
    numel(unique(caseIndices))==numel(caseIndices),'Select distinct case indices from 1 to 5.');
tag=string(datetime('now','Format','yyyyMMdd_HHmmss_SSS'));
if strlength(outputRoot)==0, outputRoot=fullfile(string(manifest.defaultOutputBase),tag); end
if isfolder(outputRoot) || isfile(outputRoot)
    error('semiphysical:ExistingOutput','Choose a new output folder: %s',outputRoot);
end
mkdir(outputRoot);
n=numel(caseIndices);
plan=table(caseIndices(:),strings(n,1),strings(n,1),strings(n,1),strings(n,1), ...
    false(n,1),repmat("prepared",n,1),nan(n,1),nan(n,1),nan(n,1),nan(n,1), ...
    'VariableNames',{'Index','Case','InputFile','ConfigPath','OutputDir', ...
    'InputExists','Status','OK','AcquiredSatellites','NavigationFixes','ElapsedSec'});
plan.ValidationOK = false(n,1);
plan.PRN11Samples = nan(n,1);
plan.PRN11ReacqMs = nan(n,1);
plan.PRN11MedianCNo = nan(n,1);
for k=1:n
    item=manifest.cases(caseIndices(k));
    config=jsondecode(fileread(fullfile(pkg,item.configFile)));
    caseDir=fullfile(outputRoot,string(item.id)); mkdir(caseDir);
    config.outDir=char(caseDir); config.tag=char(tag+"_"+string(item.id));
    cfgPath=fullfile(caseDir,'ui_config.json'); localWriteJson(cfgPath,config);
    plan.Case(k)=string(item.id);
    plan.InputFile(k)=string(fullfile(config.filePath,config.fileName));
    plan.InputExists(k)=isfile(plan.InputFile(k));
    plan.ConfigPath(k)=cfgPath; plan.OutputDir(k)=caseDir;
end
reports=cell(n,1);
batch=struct('outputRoot',outputRoot,'execute',execute,'plan',plan,'reports',{reports});
localSavePlan(batch);
if ~execute
    disp(plan(:,{'Index','Case','InputExists','Status'}));
    fprintf('Prepared JSON only; no receiver execution. Output: %s\n',outputRoot);
    return
end
addpath(char(manifest.receiverRoot)); setupPaths();
receiverStamp=struct('entry',string(which('runFromJsonConfig')), ...
    'matlabVersion',string(version), ...
    'receiverVersion',strtrim(string(fileread(fullfile(manifest.receiverRoot,'VERSION')))));
localWriteJson(fullfile(outputRoot,'receiver_runtime.json'),receiverStamp);
for k=1:n
    fprintf('\n[%d/%d] %s\n',k,n,plan.Case(k));
    plan.Status(k)="running";
    batch.plan=plan; localSavePlan(batch);
    diary(char(fullfile(plan.OutputDir(k),'matlab.log')));
    logCleaner=onCleanup(@() diary('off'));
    started=tic;
    try
        report=runFromJsonConfig(plan.ConfigPath(k), ...
            'openBaiduBrowser',false,'closeFigures',true);
    catch ME
        report=struct('ok',false,'stage','entry_error', ...
            'errorIdentifier',ME.identifier,'error',ME.message,'outDir',plan.OutputDir(k));
        localWriteJson(fullfile(plan.OutputDir(k),'report.json'),report);
    end
    plan.ElapsedSec(k)=toc(started);
    passed=report.ok;
    if report.ok
        validation=audit_semiphysical_run(plan.OutputDir(k));
        report.validation=validation;
        plan.ValidationOK(k)=validation.ok;
        for name={'PRN11Samples','PRN11ReacqMs','PRN11MedianCNo'}
            key=name{1}; field=[lower(key(1:3)) key(4:end)];
            if isfield(validation,field), plan.(key)(k)=validation.(field); end
        end
        passed=validation.ok;
        if ~passed
            report.error=strjoin(validation.issues,'; ');
        end
    end
    plan.OK(k)=double(passed);
    if passed
        plan.Status(k)="done";
    elseif report.ok
        plan.Status(k)="validation_failed";
    else
        plan.Status(k)="failed";
    end
    if isfield(report,'nAcquired'), plan.AcquiredSatellites(k)=report.nAcquired; end
    if isfield(report,'navSummary'), plan.NavigationFixes(k)=report.navSummary.nFixes; end
    reports{k}=report;
    batch.plan=plan; batch.reports=reports; localSavePlan(batch);
    clear logCleaner
    if ~passed && ~options.ContinueOnFailure
        fprintf(2,'Stopped after %s failed: %s\n',plan.Case(k),string(report.error));
        break
    elseif ~passed
        fprintf(2,'%s failed validation/execution: %s\n',plan.Case(k),string(report.error));
    end
end
disp(batch.plan(:,{'Index','Case','Status','OK','AcquiredSatellites','NavigationFixes'}));
end

function localSavePlan(batch)
writetable(batch.plan,fullfile(batch.outputRoot,'recompute_summary.csv'));
save(fullfile(batch.outputRoot,'recompute_summary.mat'),'batch');
end

function localWriteJson(path,value)
fid=fopen(path,'w','n','UTF-8');
cleaner=onCleanup(@() fclose(fid));
fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
