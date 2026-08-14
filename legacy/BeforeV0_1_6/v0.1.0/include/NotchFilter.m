function [y] = NotchFilter(x,f0,fbw,fs)
%NotchFilter generate a notch filter
%
%[y] = NotchFilter(x,f0);
%
%   Inputs:
%       x        - Input time domain signal with interference
%       f0       - Notch center frequency,Hz
%       fbw      - Notch filter 3dB bandwidth,Hz
%       fs       - Sampling frequency,Hz
%   Outputs:
%       y        - Filtered time domain signal
%
% CVS record:
% $Id: NotchFilter.m, v1.0, 2021/12/22 $
%==========================================================================
%% notch filter        

%         wo = f0/(fs/2); 
%         bw = wo/10; %品质因子Q=f0/BW
%         [b,a] = iirnotch(wo,bw);
%         d  = fdesign.notch('N,F0,Q,Ap,Ast',2,wo,6,1,10);
%         Hd = design(d,'SystemObject',true);
%         [b,a]=tf(Hd);
        
        wc  = 2*pi*f0;
%         fbw = 1e6;%0.4e6;
        wbw = 2*pi*fbw;
        
        a   = -1*wbw/2;
        b   = sqrt(4*wc^2-wbw^2)/2;
        Ts  = 1/fs;
        r1  = 0.8;
        r2  = exp(a*Ts);
        %Gain
        Kz  = (1-2*r2*cos(b*Ts)+r2^2)/(2-2*cos(wc*Ts));
        
        %Parameters of the one-pole notch filter 
        b1  = [1 -1*exp(j*2*pi*f0*Ts)];
        a1  = [1 -r1*exp(j*2*pi*f0*Ts)];
        %Parameters of the two-pole notch filter 
        b2  = [Kz -2*Kz*cos(wc*Ts) Kz];
        a2  = [1 -2*r2*cos(b*Ts) r2^2];
      
        y = filter(b1,a1,x);

end

