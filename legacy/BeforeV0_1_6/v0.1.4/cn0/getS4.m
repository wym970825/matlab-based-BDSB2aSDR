function [trackResults] = getS4(trackResults,channel)
% Input  : Idata
%          Qdata
%          LoopSettings
% Output : S4
% Parameters : BUFFLEN
BUFFLEN = 100;% 1s
trackResults = SumofVariance(trackResults,channel);
for resCnt=1:length(trackResults)
    p=trackResults(resCnt).P0_vsm;
    bufferP = p(1:BUFFLEN);
    Pmean = mean(bufferP);
    Psecmom = mean(bufferP.^2);
    S4 = zeros(1,length(p));
    S4(1) = sqrt((Psecmom-Pmean^2)/Pmean^2);
    S4(2:BUFFLEN) = repmat(S4(1),1,BUFFLEN-1);
    for dataCnt = BUFFLEN+1:length(p)
        bufferP = [p(dataCnt),bufferP(1:end-1)];
        Pmean = mean(bufferP);
        Psecmom = mean(bufferP.^2);
        S4(dataCnt) = sqrt((Psecmom-Pmean^2)/Pmean^2);
    end
    trackResults(resCnt).('S4')=S4;
end
trackResults = rmfield(trackResults,'P0_vsm');
end

