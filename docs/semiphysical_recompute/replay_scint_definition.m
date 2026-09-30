function summary = replay_scint_definition(outputDir, reviewDir, candidateDir)
% Replay PRN 11 diagnostics from saved native correlators; RF is unchanged.
% Corrected S4 is a white-Gaussian thermal-noise approximation, not DME truth.
arguments
    outputDir (1,1) string
    reviewDir (1,1) string
    candidateDir (1,1) string = ""
end
if strlength(candidateDir)>0
    addpath(candidateDir,'-begin');
    cleaner=onCleanup(@() rmpath(candidateDir));
end
if ~isfolder(reviewDir), mkdir(reviewDir); end
data=load(fullfile(outputDir,'ui_results.mat'),'settings'); s=data.settings;
assert(s.intTime==0.001 && s.longCoh_ms==1,'Audit replay currently covers native 1-ms mode.');
data=load(fullfile(outputDir,'temp','Trk_Prn_11_final.mat'),'finalTRes'); tr=data.finalTRes;
calc=scint_calculator(s);
N=numel(tr.I_P); every=s.scint_updateMs; outputs=floor(N/every);
timeSec=nan(outputs,1); rawS4=timeSec; noiseTerm=timeSec; correctedS4=timeSec;
valid=false(outputs,1); cno=45; kOut=0;
for k=1:N
    if tr.trk_state(k)==9
        calc.reset();
    end
    if k<N, remEnd=tr.remCarrPhase(k+1); else, remEnd=tr.remCarrPhase(k); end
    calc.push(tr.Pilot_I_P(k),tr.Pilot_Q_P(k),remEnd,[],logical(tr.cur_state(k)),cno);
    if calc.hasNewResult()
        r=calc.getResult();
        if mod(k,every)==0
            kOut=kOut+1; timeSec(kOut)=k*s.intTime; valid(kOut)=r.valid;
            rawS4(kOut)=r.S4_ori; noiseTerm(kOut)=r.S4_corr;
            if r.valid && isfinite(r.S4_ori) && isfinite(r.S4_corr)
                correctedS4(kOut)=sqrt(max(0,r.S4_ori^2-r.S4_corr^2));
            end
        end
    end
    % The tracking calculator receives the previous raw C/N0 estimate.
    if mod(k,s.CNoInterval)==0
        z=tr.Pilot_I_P(k-s.CNoInterval+1:k).^2+tr.Pilot_Q_P(k-s.CNoInterval+1:k).^2;
        m=mean(z); d=m^2-var(z);
        if d>0 && m>sqrt(d), cno=10*log10(sqrt(d)/(m-sqrt(d))/s.intTime); end
    end
end
rows=1:kOut;
scintReplay=table(timeSec(rows),valid(rows),rawS4(rows),noiseTerm(rows),correctedS4(rows), ...
    'VariableNames',{'TimeSec','Valid','IntensityS4Raw','GaussianNoiseTerm','S4GaussianCorrected'});
save(fullfile(reviewDir,'prn11_scint_corrected.mat'),'scintReplay','s','-v7.3');
writetable(scintReplay,fullfile(reviewDir,'prn11_scint_corrected.csv'));
summary=struct('validOutputs',nnz(valid),'totalOutputs',kOut, ...
    'firstValidSec',NaN,'rawMedian',median(rawS4(valid),'omitnan'), ...
    'correctedMedian',median(correctedS4(valid),'omitnan'), ...
    'gaussianNoiseMedian',median(noiseTerm(valid),'omitnan'), ...
    'modelCaveat','White-Gaussian thermal approximation; DME/PB residuals require separate validation');
first=find(valid,1); if ~isempty(first), summary.firstValidSec=timeSec(first); end
fid=fopen(fullfile(reviewDir,'scint_replay_summary.json'),'w','n','UTF-8');
fprintf(fid,'%s\n',jsonencode(summary,'PrettyPrint',true)); fclose(fid);
disp(summary);
end
