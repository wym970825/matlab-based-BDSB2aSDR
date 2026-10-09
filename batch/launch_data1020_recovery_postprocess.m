% All receiver stages have finished; regenerate paired maps and comparisons.
cd('F:/matlab-GNSSsdr/BDS/B2a'); setupPaths;
root='F:/matlab-GNSSsdr/BDS/B2a/results/data1020/20261009_pb_tf_comparison';
manifestPath=fullfile(root,'manifest.json');
set(groot,'defaultFigureVisible','off'); maxNumCompThreads(1);
assert(isempty(gcp('nocreate')),'Postprocessing must run without a pool.');
assert(isfile(fullfile(root,'tf_full_completion.json')));
export_data1020_satellite_maps(manifestPath);
compare_data1020_pb_tf(manifestPath);
