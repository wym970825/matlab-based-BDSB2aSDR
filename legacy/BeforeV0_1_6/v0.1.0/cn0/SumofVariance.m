function [trackResults] = SumofVariance(trackResults,channel)
intT = 1e-3;            % intergral every 1 ms
BUFFLEN = 100;          % buffer size
idx = find([channel.PRN]>0);
trackResults = trackResults(idx);
channel = channel(idx);
LChannel = length(channel);
flag0 = true;
for channelNum = 1:LChannel
    Idata = trackResults(channelNum).I_P;
    Qdata = trackResults(channelNum).Q_P;
    CN0 = zeros(1,length(Idata));
    P = zeros(1,length(Idata));
    BufferI  = Idata(1:BUFFLEN);
    BufferQ  = Qdata(1:BUFFLEN);
    [CN0(1),P(1),flag1] = VSM(BufferI,BufferQ,intT);
    CN0(2:BUFFLEN) = CN0(1);
    for datCnt= (BUFFLEN+1):length(Idata)
        flag0 = flag0&flag1;
        BufferI = [Idata(datCnt),BufferI(1:end-1)];
        BufferQ = [Qdata(datCnt),BufferQ(1:end-1)];
        [CN0(datCnt),P(datCnt),flag1] = VSM(BufferI,BufferQ,intT);% 方差估计法
    end
    flag0 = flag0&flag1;
    Success = flag0;
    trackResults(channelNum).('CNO_vsm')  = CN0;% add a new field.
    trackResults(channelNum).('flag_vsm') = Success;% add a new field.
    trackResults(channelNum).('P0_vsm')= P;
end
end
%方差求和法，计算载噪比
function [CN0,P,Success] = VSM(I,Q,T)
Z = I.^2+Q.^2;
Len = length(Z);
Ez = sum(Z)/Len;
Vz = sum((Z-Ez).^2)/(Len-1);
Ac = sqrt(Ez^2-Vz);
Siq = (Ez-Ac)/2;
CN0 = 1/T*(Ac/2/Siq);
if CN0<0
    CN0 = abs(CN0);
    Success = false;
else
    Success = true;
end
CN0 = 10*log10(CN0);
P= Ac^2;
end
