function plot_tf_grid_candidates(analysisDir)
%PLOT_TF_GRID_CANDIDATES Render saved native differences without reanalysis.
    archive=load(fullfile(analysisDir,'grid_series.mat'),'differences','summary');
    labels=cellfun(@(d) d.label,archive.differences,'UniformOutput',false);
    ix=find(strcmp(labels,'600k_9us minus 800k_3us')); assert(isscalar(ix));
    d=archive.differences{ix}; output=fullfile(analysisDir,'candidate_difference.png');
    assert(~isfile(output));
    f=figure('Visible','off','Position',[100 100 1100 930]); cleaner=onCleanup(@() close(f));
    tiledlayout(3,1,'TileSpacing','compact');
    fields={'pilot','s4','rawS4'};
    names={'Pilot C/N0 difference (dB)','Corrected S4 difference','Raw S4 difference'};
    for panel=1:3
        nexttile; y=-d.(fields{panel}); keep=isfinite(y);
        if panel==1
            plot(d.time,y,'.-');
        else
            % Finite native S4 updates are 5 s apart; do not interpolate them.
            plot(d.time(keep),y(keep),'o','MarkerSize',3);
        end
        yline(0,':'); xlim([150 715]); grid on;
        xlabel('Physical file time (s)'); ylabel(names{panel});
        ax=gca; ax.YAxis.Exponent=0;
        if panel==1
            title(sprintf('800 kHz / 3 us minus 600 kHz / 9 us; %d C/N0 updates',nnz(keep)));
        elseif panel==2
            title(sprintf('%d paired native S4 updates; full 60-s LONG support',nnz(keep)));
        end
    end
    exportgraphics(f,output,'Resolution',150);
end
