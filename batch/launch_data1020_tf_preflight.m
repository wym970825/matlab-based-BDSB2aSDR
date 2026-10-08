cd('F:/matlab-GNSSsdr/BDS/B2a'); setupPaths;
root='F:/matlab-GNSSsdr/BDS/B2a/results/data1020/20261009_pb_tf_comparison';
manifestPath=fullfile(root,'manifest.json');
set(groot,'defaultFigureVisible','off'); maxNumCompThreads(1);
rebase_data1020_pb_metadata(manifestPath);
analyze_data1020_dme(fullfile(root,'analysis_inputs.json'),0);
export_data1020_satellite_maps(manifestPath);
run_data1020_tf_pairs(manifestPath,'smoke',[1 4 6]);
compare_data1020_pb_tf('selftest');
m=jsondecode(fileread(manifestPath));
self=m; self.entries=m.entries(1); self.entries.tfDir=self.entries.pbDir;
selfPath=fullfile(root,'self_comparison_manifest.json');
fid=fopen(selfPath,'w','n','UTF-8'); fprintf(fid,'%s',jsonencode(self)); fclose(fid);
compare_data1020_pb_tf(selfPath,fullfile(root,'preflight_self_comparison'));
fid=fopen(fullfile(root,'preflight_complete.json'),'w','n','UTF-8');
fprintf(fid,'%s',jsonencode(struct('ok',true,'matlabVersion',version, ...
    'finishedAtUtc',char(datetime('now','TimeZone','UTC')),'maxWorkers',2)));
fclose(fid);
