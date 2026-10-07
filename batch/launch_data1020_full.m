cd('F:/matlab-GNSSsdr/BDS/B2a');
setupPaths;
out = 'F:/matlab-GNSSsdr/BDS/B2a/results/data1020/20261008_static_pb_run02';
try
    verify_data1020_parallel_acquisition(out);
    run_data1020_experiments('full',out,1:7);
catch ME
    fprintf(2,'%s\n',getReport(ME,'extended','hyperlinks','off'));
    fid=fopen(fullfile(out,'full_launcher_error.txt'),'w');
    if fid>0, fprintf(fid,'%s',getReport(ME,'extended','hyperlinks','off')); fclose(fid); end
    exit(1)
end
exit(0)
