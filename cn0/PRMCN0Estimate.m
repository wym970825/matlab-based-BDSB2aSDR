function [trackResults] = PRMCN0Estimate(trackResults,channel)
%方差求和法，计算哉噪比
intT = 1e-3;% intergral every 1 ms
BUFFLEN = 1000;% buffer size
idx = find([channel.PRN]>0);
trackResults = trackResults(idx);
channel = channel(idx);
LChannel = length(channel);
for channelNum = 1:LChannel
    Idata = trackResults(channelNum).I_P;
    Qdata = trackResults(channelNum).Q_P;
    Ratio = zeros(1,length(Idata));
    BufferI  = Idata(1:BUFFLEN);
    BufferQ  = Qdata(1:BUFFLEN);
    Ratio(1) = PRM(BufferI,BufferQ);
    Ratio(2:BUFFLEN) = Ratio(1);
    for datCnt= (BUFFLEN+1):length(Idata)
        BufferI = [Idata(datCnt),BufferI(1:end-1)];
        BufferQ = [Qdata(datCnt),BufferQ(1:end-1)];
        Ratio(datCnt) = PRM(BufferI,BufferQ);
    end
    b = (1/BUFFLEN)*ones(1,BUFFLEN);a = 1;
    Ratio = filter(b,a,Ratio);
    CN0 = (1/intT)*(Ratio-1)./(BUFFLEN-Ratio);
    CN0 = abs(CN0);
    CN0 = 10*log10(CN0);
end
end

function [Ratio]=PRM(I,Q)
WBP = sum(I.^2+Q.^2);
NBP = sum(I)^2+sum(Q)^2;
Ratio = (NBP/WBP);
end

