function plotTracking_NHSMKF(channelList, trackResults, settings)
% plotTracking_NHSMKF
% Result visualization for tracking with NH state machine + FLL-aided + KF logs.
%
% Figures (per channel):
%   1) (optional) call legacy plotTracking() for PLL/DLL overall view
%   2) FLL + KF metrics figure
%   3) State machine + performance summary figure
%
% Usage:
%   plotTracking_NHSMKF(1:settings.numberOfChannels, trackResults, settings)

% --- protect channel list
channelList = intersect(channelList, 1:settings.numberOfChannels);

% --- 1) Keep your existing "overall PLL/DLL" plots (if you want)
%     (only if legacy plotTracking.m exists and it's not this function)
if exist('plotTracking','file') == 2
    try
        plotTracking(channelList, trackResults, settings);
    catch
        % ignore if legacy plotTracking fails (so new plots still appear)
    end
end

% --- time axis
% Use actual length from fields if possible (some runs may be shorter than msToProcess)
defaultN = settings.msToProcess;
t = (1:defaultN)/1000;

for ch = channelList
    if trackResults(ch).status ~= 'T'
        continue;
    end

    % --- infer length N
    N = defaultN;
    if isprop(trackResults(ch),'pllDiscrFilt') && ~isempty(trackResults(ch).pllDiscrFilt)
        N = min(N, numel(trackResults(ch).pllDiscrFilt));
    end
    t = (1:N)/1000;

    % --- field existence flags (so this function works even if some logs missing)
    hasFLL = isprop(trackResults(ch),'fllDiscrHz') && ~isempty(trackResults(ch).fllDiscrHz);
    hasKF  = isprop(trackResults(ch),'kf_phiRad')  && ~isempty(trackResults(ch).kf_phiRad);
    hasState = isprop(trackResults(ch),'trk_state') && ~isempty(trackResults(ch).trk_state);

    % =====================================================================
    % Figure A: FLL loop + KF filter metrics
    % =====================================================================
    figA = figure(ch + 300);
    clf(figA);
    figA.Name = sprintf('CH %d (PRN %d) - FLL & KF', ch, trackResults(ch).PRN);
    figA.Position = [80 80 1500 850];

    % helper: background shading for FLL-aided periods
    aided = false(1,N);
    if isprop(trackResults(ch),'fllAided') && ~isempty(trackResults(ch).fllAided)
        aided = logical(trackResults(ch).fllAided(1:N));
    end

    % Subplots layout
    % Row1: FLL discr raw / filt / applied corr
    ax1 = subplot(3,3,1); hold(ax1,'on'); grid(ax1,'on'); title(ax1,'FLL discr raw (Hz)');
    ax2 = subplot(3,3,2); hold(ax2,'on'); grid(ax2,'on'); title(ax2,'FLL discr filt (Hz)');
    ax3 = subplot(3,3,3); hold(ax3,'on'); grid(ax3,'on'); title(ax3,'FLL corr applied (Hz)');

    % Row2: KF states / corr
    ax4 = subplot(3,3,4); hold(ax4,'on'); grid(ax4,'on'); title(ax4,'KF \omega err (Hz)');
    ax5 = subplot(3,3,5); hold(ax5,'on'); grid(ax5,'on'); title(ax5,'KF \phi err (rad)');
    ax6 = subplot(3,3,6); hold(ax6,'on'); grid(ax6,'on'); title(ax6,'KF corr applied (Hz)');

    % Row3: NIS + RMS innovation
    ax7 = subplot(3,3,7); hold(ax7,'on'); grid(ax7,'on'); title(ax7,'NIS (phi / omega)');
    ax8 = subplot(3,3,8); hold(ax8,'on'); grid(ax8,'on'); title(ax8,'RMS innovation (phi / omega)');
    ax9 = subplot(3,3,9); hold(ax9,'on'); grid(ax9,'on'); title(ax9,'FLL aided flag');

    % --- FLL plots
    if hasFLL
        fllRaw  = trackResults(ch).fllDiscrHz(1:N);
        fllFilt = trackResults(ch).fllDiscrFiltHz(1:N);
        plot(ax1, t, fllRaw);
        plot(ax2, t, fllFilt);

        if isprop(trackResults(ch),'fllCorrHz') && ~isempty(trackResults(ch).fllCorrHz)
            fllCorr = trackResults(ch).fllCorrHz(1:N);
            plot(ax3, t, fllCorr);
        else
            plot(ax3, t, zeros(1,N));
        end
    else
        text(ax2,0.05,0.5,'(no FLL fields)','Units','normalized');
    end

    % --- KF plots
    if hasKF
        if isprop(trackResults(ch),'kf_omegaHz') && ~isempty(trackResults(ch).kf_omegaHz)
            plot(ax4, t, trackResults(ch).kf_omegaHz(1:N));
        end
        if isprop(trackResults(ch),'kf_phiRad') && ~isempty(trackResults(ch).kf_phiRad)
            plot(ax5, t, trackResults(ch).kf_phiRad(1:N));
        end
        if isprop(trackResults(ch),'kf_corrHz') && ~isempty(trackResults(ch).kf_corrHz)
            plot(ax6, t, trackResults(ch).kf_corrHz(1:N));
        end

        if isprop(trackResults(ch),'kf_nisPhi') && ~isempty(trackResults(ch).kf_nisPhi)
            l1 = plot(ax7, t, trackResults(ch).kf_nisPhi(1:N), 'DisplayName','NIS\_phi');
        end
        if isprop(trackResults(ch),'kf_nisOmega') && ~isempty(trackResults(ch).kf_nisOmega)
            l2 = plot(ax7, t, trackResults(ch).kf_nisOmega(1:N), 'DisplayName','NIS\_\omega');
        end
        legend(ax7,[l1,l2],{'$NIS_\phi$','$NIS_\omega$'},...
            'Location','best','interpreter','latex','AutoUpdate','off');

        if isprop(trackResults(ch),'kf_rmsNuPhiRad') && ~isempty(trackResults(ch).kf_rmsNuPhiRad)
            l1 = plot(ax8, t, trackResults(ch).kf_rmsNuPhiRad(1:N), 'DisplayName','RMS \nu\_\phi (rad)');
        end
        if isprop(trackResults(ch),'kf_rmsNuOmegaHz') && ~isempty(trackResults(ch).kf_rmsNuOmegaHz)
            l2 = plot(ax8, t, trackResults(ch).kf_rmsNuOmegaHz(1:N), 'DisplayName','RMS \nu\_\omega (Hz)');
        end
        legend(ax8,[l1,l2],{'RMS $\nu_\phi$ (rad)','RMS $\nu_\omega$ (Hz)'},...
            'Location','best','interpreter','latex','AutoUpdate','off');
    else
        text(ax5,0.05,0.5,'(no KF fields)','Units','normalized');
    end

    % --- aided flag
    stairs(ax9, t, double(aided), 'LineWidth', 1.0);
    ylim(ax9, [-0.1 1.1]);
    xlabel(ax9,'Time (s)');

    % Plot background shading where aided==1
    shadeAxes = [ax1 ax2 ax3 ax4 ax5 ax6 ax7 ax8];
    for ax = shadeAxes
        yL = ylim(ax); %#ok<NASGU>
        addAidingShade(ax, t, aided);
    end

    % link x axes
    linkaxes([ax1 ax2 ax3 ax4 ax5 ax6 ax7 ax8 ax9],'x');

    % =====================================================================
    % Figure B: State machine + performance summary
    % =====================================================================
    figB = figure(ch + 400);
    clf(figB);
    figB.Name = sprintf('CH %d (PRN %d) - State & Performance', ch, trackResults(ch).PRN);
    figB.Position = [120 120 1500 850];

    bx1 = subplot(4,1,1); hold(bx1,'on'); grid(bx1,'on');
    title(bx1,'Tracking state (trk\_state) and FLL aided');
    bx2 = subplot(4,1,2); hold(bx2,'on'); grid(bx2,'on');
    title(bx2,'C/N0 (Pilot/Data)'); ylabel(bx2,'dB-Hz');
    bx3 = subplot(4,1,3); hold(bx3,'on'); grid(bx3,'on');
    title(bx3,'Carrier freq / PLL'); ylabel(bx3,'Hz');
    bx4 = subplot(4,1,4); hold(bx4,'on'); grid(bx4,'on');
    title(bx4,'Code freq / DLL'); ylabel(bx4,'Hz'); xlabel(bx4,'Time (s)');

    % --- state plot
    if hasState
        st = double(trackResults(ch).trk_state(1:N));
        stairs(bx1, t, st, 'LineWidth', 1.0, 'DisplayName','trk\_state');
        yyaxis(bx1,'right');
        stairs(bx1, t, double(aided), 'LineWidth', 1.0, 'DisplayName','FLL aided');
        ylim(bx1, [-0.1 1.1]);
        ylabel(bx1,'aided');
        yyaxis(bx1,'left');
        ylabel(bx1,'state id');
        % annotate state ids
        stateLegendText = "1 INIT, 2 INIT_FLL, 3 LONG, 4 LONG_FLL, 9 REACQ";
        text(bx1, 0.01, 0.92, stateLegendText, 'Units','normalized');
    else
        text(bx1,0.05,0.5,'(no trk\_state field)','Units','normalized');
    end

    % --- CN0 plot
    if isprop(trackResults(ch),'PilotCNo') && ~isempty(trackResults(ch).PilotCNo)
        TimeScale = (0:numel(trackResults(ch).PilotCNo)-1) * settings.CNoInterval/1e3;
        plot(bx2, TimeScale, trackResults(ch).PilotCNo, 'DisplayName','Pilot');
    end
    if isprop(trackResults(ch),'DataCNo') && ~isempty(trackResults(ch).DataCNo)
        TimeScale = (0:numel(trackResults(ch).DataCNo)-1) * settings.CNoInterval/1e3;
        plot(bx2, TimeScale, trackResults(ch).DataCNo, 'DisplayName','Data');
    end
    legend(bx2,'show','Location','best');

    % --- carrier performance
    if isprop(trackResults(ch),'carrFreq') && ~isempty(trackResults(ch).carrFreq)
        plot(bx3, t, trackResults(ch).carrFreq(1:N), 'DisplayName','carrFreq');
    end
    if isprop(trackResults(ch),'pllDiscrFilt') && ~isempty(trackResults(ch).pllDiscrFilt)
        yyaxis(bx3,'right');
        plot(bx3, t, trackResults(ch).pllDiscrFilt(1:N), 'DisplayName','pllDiscrFilt');
        ylabel(bx3,'PLL discr (cycles or rad)');
        yyaxis(bx3,'left');
    end
    legend(bx3,'show','Location','best');

    % --- code performance
    if isprop(trackResults(ch),'codeFreq') && ~isempty(trackResults(ch).codeFreq)
        plot(bx4, t, trackResults(ch).codeFreq(1:N), 'DisplayName','codeFreq');
    end
    if isprop(trackResults(ch),'dllDiscrFilt') && ~isempty(trackResults(ch).dllDiscrFilt)
        yyaxis(bx4,'right');
        plot(bx4, t, trackResults(ch).dllDiscrFilt(1:N), 'DisplayName','dllDiscrFilt');
        ylabel(bx4,'DLL discr');
        yyaxis(bx4,'left');
    end
    legend(bx4,'show','Location','best');

    linkaxes([bx1 bx2 bx3 bx4],'x');
end

end

% ======================================================================
% Local helper: shade aided periods
% ======================================================================
function addAidingShade(ax, t, aided)
if isempty(aided) || ~any(aided)
    return;
end
yl = ylim(ax);
hold(ax,'on');
set(ax,'YLim',yl,'YLimMode','manual');
% Find contiguous segments where aided==1
a = aided(:).';
d = diff([0 a 0]);
st = find(d==1);
ed = find(d==-1)-1;

for i=1:numel(st)
    x1 = t(st(i));
    x2 = t(ed(i));
    patch(ax, [x1 x2 x2 x1], [yl(1) yl(1) yl(2) yl(2)], [0.7 0.7 0.7], ...
        'EdgeColor','none', 'FaceAlpha',0.4);
end
uistack(findobj(ax,'Type','patch'),'bottom');
end
