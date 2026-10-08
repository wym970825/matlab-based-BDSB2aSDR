cd('F:/matlab-GNSSsdr/BDS/B2a'); setupPaths;
root='F:/matlab-GNSSsdr/BDS/B2a/results/data1020/20261009_pb_tf_comparison';
manifestPath=fullfile(root,'manifest.json');
set(groot,'defaultFigureVisible','off'); maxNumCompThreads(1);
assert(isfile(fullfile(root,'preflight_complete.json')),'Complete smoke and preflight first.');
run_data1020_tf_pairs(manifestPath,'full',1:6);
pool=gcp('nocreate'); if ~isempty(pool), delete(pool); end
export_data1020_satellite_maps(manifestPath);
compare_data1020_pb_tf(manifestPath);
