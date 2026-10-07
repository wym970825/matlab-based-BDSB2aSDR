function verify_data1020_parallel_acquisition(root)
% Compare every acquisition field on actual zero/nonzero-IF inputs, including
% detected and undetected PRNs. Keep all results beside the experiment.
    setupPaths;
    records=cell(1,2);
    files={'01_HUR.json','06_103801.json'};
    for k=1:2
        raw=jsondecode(fileread(fullfile(root,'configs',files{k})));
        raw.acqSatelliteList=[1 27 38]; raw.parMaxWorkers=6;
        s=initSettings(raw);
        [fid,coeff]=openIfFile(s); cleaner=onCleanup(@() fclose(fid));
        s.useParallelAcquisition=false; started=tic;
        serial=runAcquisition(fid,s,coeff); serialSeconds=toc(started);
        fseek(fid,0,'bof');
        s.useParallelAcquisition=true; started=tic;
        parallel=runAcquisition(fid,s,coeff); parallelSeconds=toc(started);
        assert(isequaln(serial,parallel),'data1020:AcquisitionMismatch', ...
            'Serial and parallel acquisition fields differ for %s.',files{k});
        records{k}=struct('config',files{k},'exactAllFieldEquality',true, ...
            'prns',s.acqSatelliteList,'detected',serial.detected, ...
            'serialSeconds',serialSeconds,'parallelSeconds',parallelSeconds);
        clear cleaner
    end
    fid=fopen(fullfile(root,'parallel_acquisition_verification.json'),'w');
    cleaner=onCleanup(@() fclose(fid));
    fprintf(fid,'%s\n',jsonencode([records{:}],'PrettyPrint',true));
end
