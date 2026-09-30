function f=tf_notch_coefficients(kind,fs,centerHz,widthHz,taps,transitionHz)
% Lab design. FIR width = flat stopband; IIR width = full -3 dB width.
arguments
    kind (1,1) string
    fs (1,1) double {mustBePositive}
    centerHz (1,1) double
    widthHz (1,1) double {mustBePositive}
    taps (1,1) double = 641
    transitionHz (1,1) double = 150e3
end
assert(abs(centerHz)+widthHz/2+transitionHz<fs/2,'Band must fit the sampled spectrum.');
f=struct('kind',kind,'fs',fs,'centerHz',centerHz,'widthHz',widthHz);
if kind=="iir"
    t=tan(pi*widthHz/(2*fs)); r=(1-t)/(1+t);
    assert(r>0 && r<1);
    q=exp(1i*2*pi*centerHz/fs); gain=(1+r)/2;
    f.b=gain*[1 -q]; f.a=[1 -r*q]; f.delay=0; f.radius=r;
    f.tail=ceil(log(1e-3)/log(r));
    f.widthDefinition='full -3 dB width, unity response opposite the notch';
elseif kind=="fir"
    assert(mod(taps,2)==1 && taps>=3);
    D=(taps-1)/2;
    low=fir1(taps-1,(widthHz/2+transitionHz/2)/(fs/2),kaiser(taps,5.65326));
    % The (n-D) phase origin is essential for cancellation against delta[n-D].
    f.b=-low.*exp(1i*2*pi*centerHz/fs*(-D:D)); f.b(D+1)=f.b(D+1)+1;
    f.a=1; f.delay=D; f.tail=D; f.radius=NaN;
    f.widthDefinition='full flat stopband, transition on each side specified separately';
else
    error('Unsupported laboratory filter kind.');
end
end
