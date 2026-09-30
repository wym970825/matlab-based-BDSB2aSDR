function alignment=estimate_rf_relative_lags(runRoot)
% Data-driven lag hypotheses, not an injection-truth or time-system mapping.
runRoot=char(runRoot); state=jsondecode(fileread(fullfile(runRoot,'supervisor.json')));
items=state.cases; if ~iscell(items), items=num2cell(items); end
reference=features(items{1}.outputDir);
rows={};
for k=2:numel(items)
    item=items{k}; if ~strcmp(item.status,'done'), continue; end
    value=features(item.outputDir); lags=-120:120; p=nan(size(lags)); c=p;
    % Identical reference interval for every tested lag avoids rewarding
    % candidates simply because they retain a different section of data.
    t=250:(min(numel(reference.power),numel(value.power))-120);
    for j=1:numel(lags)
        q=t+lags(j);
        p(j)=correlation(reference.power(t),value.power(q));
        c(j)=correlation(reference.cno(t),value.cno(q));
    end
    [bestP,ip]=max(p); [bestC,ic]=max(c);
    rows{end+1}=struct('case',item.('case'),'powerLagSec',lags(ip), ...
        'powerCorrelation',bestP,'cnoLagSec',lags(ic),'cnoCorrelation',bestC); %#ok<AGROW>
end
alignment=struct('reference',items{1}.('case'), ...
    'definition','positive lag means feature occurs later in this RF recording than in the reference', ...
    'resolutionSec',1,'status','hypothesis from correlator power and C/N0; independent truth not supplied', ...
    'cases',[rows{:}]);
fid=fopen(fullfile(runRoot,'review','relative_lag_hypotheses.json'),'w','n','UTF-8');
fprintf(fid,'%s\n',jsonencode(alignment,'PrettyPrint',true)); fclose(fid);
disp(alignment.cases);
end

function f=features(folder)
d=load(fullfile(folder,'temp','Trk_Prn_11_final.mat'),'finalTRes'); tr=d.finalTRes;
N=floor(numel(tr.I_P)/1000)*1000;
power=reshape(tr.Pilot_I_P(1:N).^2+tr.Pilot_Q_P(1:N).^2,1000,[]);
f.power=log(max(mean(power,1),realmin));
f.cno=mean(reshape(tr.B2a_CNo(1:N/200),5,[]),1);
end

function r=correlation(a,b)
ok=isfinite(a)&isfinite(b); a=a(ok); b=b(ok);
a=a-mean(a); b=b-mean(b);
r=sum(a.*b)/sqrt(sum(a.^2)*sum(b.^2));
end
