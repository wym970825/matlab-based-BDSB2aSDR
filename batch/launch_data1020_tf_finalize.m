% Finish saved-result checks and publication figures after the full queue.
% This script never reruns acquisition, tracking, or navigation.
cd('F:/matlab-GNSSsdr/BDS/B2a'); setupPaths;
root='F:/matlab-GNSSsdr/BDS/B2a/results/data1020/20261009_pb_tf_comparison';
manifestPath=fullfile(root,'manifest.json');
set(groot,'defaultFigureVisible','off'); maxNumCompThreads(1);
assert(isfile(fullfile(root,'tf_full_completion.json')),'The full TF queue has not completed.');
manifest=jsondecode(fileread(manifestPath));
for k=1:numel(manifest.entries)
    entry=manifest.entries(k);
    v=jsondecode(fileread(fullfile(entry.tfDir,'validation.json')));
    assert(v.pipelineOk && v.allAcquiredTracked && v.thresholdMatchesBaseline, ...
        'TF experiment %d failed its receiver audit.',entry.experimentNumber);
end
compare_data1020_pb_tf('selftest');
export_data1020_acquisition_figures(manifestPath,{'PB','TF'});
export_data1020_tracking_figures(manifestPath,{'PB','TF'});
close all force;
fid=fopen(fullfile(root,'postprocessing_complete.json'),'w','n','UTF-8');
assert(fid>0); cleanup=onCleanup(@() fclose(fid));
fprintf(fid,'%s\n',jsonencode(struct('ok',true,'receiverRerun',false, ...
    'completedAtUtc',char(datetime('now','TimeZone','UTC'))),'PrettyPrint',true));
