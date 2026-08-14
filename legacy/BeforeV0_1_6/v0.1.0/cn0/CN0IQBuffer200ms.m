classdef CN0IQBuffer200ms
    properties
        BufferVal = nan(2,200);
        CN0 = nan(1);
        PWR = nan(1);
        PLD = nan(1);
        Success = nan(1);
    end
    properties(Access = private)
        Isempty = true;
        Isfull = false;
    end
    methods(Static = true)
        %% Send data to the queue
        %----------------------------------------%

        function buf = QueuePush(buf,dat)
            arguments
                buf
                dat (2,:) {mustBeNumericOrLogical}
            end
            LofDat = size(dat,2);
            if LofDat>=200
                buf.BufferVal = dat(:,1:200);
            else
                buf.BufferVal(:,LofDat+1:200) = buf.BufferVal(:,1:200-LofDat);
                buf.BufferVal(:,1:LofDat) = dat;
            end
            buf = buf.QueueStateUpdate(buf);
        end
        %% Empty the queue
        %----------------------------------------%
        function buf = QueueClear(buf)
            buf.BufferVal = nan(2,200);
            buf = buf.QueueStateUpdate(buf);
        end

        function buf = QueueStateUpdate(buf)
            NanNum = sum(sum(isnan(buf.BufferVal)));
            if NanNum==400
                buf.Isempty = true;
                buf.Isfull = false;
                buf.CN0 = nan(1);
                buf.PWR = nan(1);
                buf.Success = nan(1);
            elseif NanNum==0
                buf.Isfull = true;
                buf.Isempty = false;
                buf = VSM(buf);
            else
                buf.Isempty = false;
                buf.Isfull = false;
                buf.CN0 = nan(1);
                buf.PWR = nan(1);
                buf.Success = nan(1);
            end
        end
        %% calculate carrier 2 noise ratio
        %----------------------------------------%
        
    end
end
%% ----------------------------- %%
%%%%%%%%%%%%% private %%%%%%%%%%%%%
%---------------------------------%
function [buf] = VSM(buf)
I = buf.BufferVal(1,:);
Q = buf.BufferVal(2,:);
Z = I.^2+Q.^2;
Len = length(Z);
Ez = sum(Z)/Len; 
Vz = sum((Z-Ez).^2)/(Len-1);
Ac = sqrt(Ez^2-Vz);
Siq = (Ez-Ac)/2;
CN0 = 1000*(Ac/2/Siq);
if CN0<0
    CN0 = abs(CN0);
    buf.Success = false;
else
    buf.Success = true;
end
% % Wide Band Power (WBP)
% WBP = sum(Z);
% NBP = sum(I).^2+sum(Q).^2;
% PLL lock detector output
% Narrow Band power
NBP = (sum(I(I>0)) - sum(I(I<0)))^2 + sum(Q)^2;
NBD = (sum(I(I>0)) - sum(I(I<0)))^2 - sum(Q)^2;
% PLL lock detector output
buf.PLD = NBD/NBP;
% carrier to noise ration
buf.CN0 = 10*log10(CN0);
% power of signaal
buf.PWR = Ac^2;
end
