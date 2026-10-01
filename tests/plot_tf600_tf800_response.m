function plot_tf600_tf800_response(configPath,outputPath)
%PLOT_TF600_TF800_RESPONSE Actual complex FIR branch response near interference.
    setupPaths(); config=jsondecode(fileread(configPath));
    assert(~isfile(outputPath),'TFResponse:OutputExists','Use a fresh output path.');
    f=figure('Visible','off','Position',[100 100 1100 760]); cleanup=onCleanup(@() close(f));
    tiledlayout(2,1); frequency=linspace(-1.2e6,.4e6,16001);
    for fs=[25e6 30.69e6]
        nexttile; hold on;
        for bandwidth=[600e3 800e3]
            config.samplingFreq=fs;
            config.Frontend=struct('mode','tf_v1','TF',struct('stopbandWidthHz',bandwidth));
            filter=TFBlankerV1(config);
            response=freqz(filter.Notch,1,2*pi*frequency/fs);
            plot(frequency/1e3,20*log10(max(abs(response),1e-7)), ...
                'LineWidth',1,'DisplayName',sprintf('%g kHz',bandwidth/1e3));
        end
        xline(0,':','Digital 0 Hz','HandleVisibility','off');
        grid on; ylim([-100 2]); xlim([-1200 400]);
        xlabel('Digital IQ frequency (kHz)'); ylabel('FIR branch magnitude (dB)');
        title(sprintf('Fixed center -450 kHz; fs=%.2f MHz; %d taps',fs/1e6,filter.Config.effectiveTaps));
        legend('Location','best');
    end
    exportgraphics(f,outputPath,'Resolution',150);
end
