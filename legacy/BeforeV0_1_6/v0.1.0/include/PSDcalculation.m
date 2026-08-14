%Calculate the PSD of the detrended carrier phase measurements£¬ phi_detrended_cur £¨50 Hz data£©
nfft = 2 ^ nextpow2(length(phi_detrended_cur));   %Define the number of points for fft calculation
%nfft = 50;
dft_carrerPha = fft(phi_detrended_cur, nfft);        %FFT for detrended carrier phase
numunique = ceil((nfft + 1) / 2);                               %calculate number of unique points
dft_carrerPha = dft_carrerPha(1 : numunique);     %throw away second half with minor frequency (f < 0)
Power_dft_carrerPha = abs(dft_carrerPha);          %Calculate the magnitude of dft_carrerPha
        
%Calculate the power and scale it to get the power density
Power_dft_carrerPha= 1 / 50 / length(phi_detrended_cur) * Power_dft_carrerPha .^ 2;
        
%frequency vector with numunique points
%det_f = f_max / Nfft = SampleRate/Nfft, sample resolution, sample
%increment
fmw = (0 : numunique - 1) * 50 / nfft;      