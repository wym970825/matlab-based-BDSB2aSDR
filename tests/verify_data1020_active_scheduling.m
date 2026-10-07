function verify_data1020_active_scheduling(root)
% Compare updated scheduling with six real channels saved by the old scheduler.
% Retain 63 slots to exercise the sparse-channel case without changing loops.
    base=fullfile(root,'full_01_HUR');
    S=load(fullfile(base,'ui_results.mat'),'results','settings');
    s=S.settings; s.msToProcess=500; s.numberOfChannels=63;
    s.resultRoot=fullfile(root,'active_scheduling_verification');
    assert(~isfolder(s.resultRoot),'Verification output exists.'); mkdir(s.resultRoot);
    s.tempdataSvPth=fullfile(s.resultRoot,'temp'); mkdir(s.tempdataSvPth);
    a=S.results.acqResults;
    keep=ismember(s.acqSatelliteList,[27 28 33 38 39 41]);
    a.detected=a.detected & keep;
    ch=preRun2(a,s);
    [fid,~]=openIfFile(s); cleaner=onCleanup(@() fclose(fid));
    [tr,~]=tracking2_v6_fix2(fid,ch,s);
    fields={'absoluteSample','I_P','Q_P','Pilot_I_P','Pilot_Q_P', ...
        'codeFreq','carrFreq','dllDiscr','pllDiscr','trk_state','eta'};
    for k=1:6
        old=load(fullfile(base,'temp',sprintf('Trk_Prn_%d_final.mat',tr(k).PRN)),'finalTRes');
        for j=1:numel(fields)
            key=fields{j}; expected=old.finalTRes.(key); expected=expected(1:500);
            actual=tr(k).(key);
            assert(isequaln(actual(:),expected(:)), ...
                'data1020:SchedulingMismatch','Mismatch PRN %d field %s',tr(k).PRN,key);
        end
    end
    assert(all([tr(7:end).PRN]==0),'Inactive channel mapping changed.');
    result=struct('exactEquality',true,'prns',[tr(1:6).PRN], ...
        'comparedMs',500,'comparedFields',{fields},'allocatedSlots',63, ...
        'activeTasks',6,'inactiveSlotsPreserved',true);
    fid2=fopen(fullfile(root,'active_scheduling_verification.json'),'w');
    cleaner2=onCleanup(@() fclose(fid2));
    fprintf(fid2,'%s\n',jsonencode(result,'PrettyPrint',true));
end
