cd('F:/matlab-GNSSsdr/BDS/B2a');
setupPaths;
out = 'F:/matlab-GNSSsdr/BDS/B2a/results/data1020/20261008_static_pb_run02';
try
    run_data1020_experiments('prepare',out);
    run_data1020_experiments('smoke',out,[1 6 7]);
catch ME
    fprintf(2,'%s\n',getReport(ME,'extended','hyperlinks','off'));
    if isfolder(out)
        fid=fopen(fullfile(out,'smoke_launcher_error.txt'),'w');
        if fid>0, fprintf(fid,'%s',getReport(ME,'extended','hyperlinks','off')); fclose(fid); end
    end
    exit(1)
end
exit(0)
