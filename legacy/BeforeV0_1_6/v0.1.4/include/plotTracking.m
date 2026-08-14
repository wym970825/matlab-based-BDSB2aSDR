function plotTracking(channelList, trackResults, settings)
%This function plots the tracking results for the given channel list.
%
%plotTracking(channelList, trackResults, settings)
%
%   Inputs:
%       channelList     - list of channels to be plotted.
%       trackResults    - tracking results from the tracking function.
%       settings        - receiver settings.

%--------------------------------------------------------------------------
%                           SoftGNSS v3.0
%
% Copyright (C) Darius Plausinaitis
% Written by Darius Plausinaitis
%--------------------------------------------------------------------------
%This program is free software; you can redistribute it and/or
%modify it under the terms of the GNU General Public License
%as published by the Free Software Foundation; either version 2
%of the License, or (at your option) any later version.
%
%This program is distributed in the hope that it will be useful,
%but WITHOUT ANY WARRANTY; without even the implied warranty of
%MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%GNU General Public License for more details.
%
%You should have received a copy of the GNU General Public License
%along with this program; if not, write to the Free Software
%Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
%USA.
%--------------------------------------------------------------------------

%CVS record:
%$Id: plotTracking.m,v 1.5.2.23 2006/08/14 14:45:14 dpl Exp $

% Protection - if the list contains incorrect channel numbers
channelList = intersect(channelList, 1:settings.numberOfChannels);
%=== For all listed channels ==============================================
for channelNr = channelList
    
    if trackResults(channelNr).status == 'T'      
        %% Select (or create) and clear the figure ========================
    % The number 200 is added just for more convenient handling of the open
    % figure windows, when many figures are closed and reopened.
    % Figures drawn or opened by the user, will not be "overwritten" by
    % this function.
    
    figure(channelNr +200);
    fig = gcf();fig.Position = [100,100,1400,800];
    clf(channelNr +200);
    set(channelNr +200, 'Name', ['Channel ', num2str(channelNr), ...
        ' (PRN ', ...
        num2str(trackResults(channelNr).PRN), ...
        ') results']);
    
        %% Draw axes ======================================================
    % Row 1
    h_IQ = subplot(3, 4, 1);
    h_I_d = subplot(3, 4, [2,3]);
    h_CN0 = subplot(3, 4, 4);
    % Row 2
    
    h_pwr_D = subplot(3, 4, [5 6]);
    h_pwr_P = subplot(3, 4, [7 8]);
    % Row 3
    h_PLL_f = subplot(3, 4, 9);
    h_PLL_o = subplot(3, 4, 10);
    h_DLL_f = subplot(3, 4, 11);
    h_DLL_o = subplot(3, 4, 12);
    
        %% Plot all figures ===============================================
        Clrs = cool(2);
        pilotClr = Clrs(1,:);
        dataClr = Clrs(2,:);
        lw = 0.1;
        FN = 'Arial';
        FS = 9;
        timeAxisInSeconds = (1:settings.msToProcess)/1000;
    
    %----- Discrete-Time Scatter Plot ---------------------------------
    hold(h_IQ,'on');
    l1 = scatter(h_IQ, trackResults(channelNr).I_P,...
        trackResults(channelNr).Q_P, 2,dataClr,'filled','o', ...
        'markeredgecolor','none','markeredgealpha',0.5); 
    
    l2 = scatter(h_IQ, trackResults(channelNr).Pilot_I_P,...
        trackResults(channelNr).Pilot_Q_P, 2, pilotClr,'filled','o', ...
        'markeredgecolor','none','markeredgealpha',0.5); 
    
    grid  (h_IQ);
    axis  (h_IQ, 'equal');
    title (h_IQ, 'IQ Scatter Plot');
    xlabel(h_IQ, 'I_p');
    ylabel(h_IQ, 'Q_p');
    set(h_IQ, "Box",'on',"FontName",FN,'FontSize',FS);
    legend([l1,l2],{'Data','Pilot'},"FontName",'Arial','FontSize',7,'Location','best','BackgroundAlpha',0);
    
    %----- Nav bits ---------------------------------------------------
    plot(h_I_d, timeAxisInSeconds, ...
        trackResults(channelNr).I_P, 'Color',dataClr,'LineWidth',lw);

    grid  (h_I_d);
    title (h_I_d, 'Bits of the navigation message');
    xlabel(h_I_d, 'Time (s)');
    axis  (h_I_d, 'tight');
    set(h_I_d, "Box",'on',"FontName",FN,'FontSize',FS);

    %----- CN0 plot --------------------------------------------------- 
    hold(h_CN0,'on');
    TimeScale = (0:length(trackResults(channelNr).DataCNo)-1)*settings.CNoInterval/1e3; % each CN0 calculation interval 200msec;
    PCN0 = trackResults(channelNr).PilotCNo;
    DCN0 = trackResults(channelNr).DataCNo;
    ylimt = [min(35,min([PCN0,DCN0])),max(max(PCN0),max(DCN0))];
    L_P = plot(h_CN0, TimeScale, ...
        PCN0, 'Color',pilotClr,'LineWidth',lw);
    L_D = plot(h_CN0, TimeScale, ...
        DCN0, 'Color',dataClr,'LineWidth',lw);
    grid  (h_CN0);
    title (h_CN0, 'CN_0');
    xlabel(h_CN0, 'Time (s)');
    ylabel(h_CN0, 'CN_0 dB\cdot Hz');
    set(h_CN0, "Box",'on',"FontName",FN,'FontSize',FS,'YLim',ylimt);
    legend([L_D,L_P],{'Data','Pilot'},"FontName",'Arial','FontSize',7,'Location','best','BackgroundAlpha',0);
    %----- PLL discriminator unfiltered--------------------------------
    plot  (h_PLL_f, timeAxisInSeconds, ...
        trackResults(channelNr).pllDiscr, 'r');
    
    grid  (h_PLL_f);
    axis  (h_PLL_f, 'tight');
    xlabel(h_PLL_f, 'Time (s)');
    ylabel(h_PLL_f, 'Amplitude');
    title (h_PLL_f, 'Raw PLL discriminator');
    
    %----- Correlation ------------------------------------------------
    plot(h_pwr_D, timeAxisInSeconds, ...
        [sqrt(trackResults(channelNr).I_E.^2 + ...
        trackResults(channelNr).Q_E.^2)', ...
        sqrt(trackResults(channelNr).I_P.^2 + ...
        trackResults(channelNr).Q_P.^2)', ...
        sqrt(trackResults(channelNr).I_L.^2 + ...
        trackResults(channelNr).Q_L.^2)'], ...
        '-','LineWidth',lw);
    
    grid  (h_pwr_D);
    title (h_pwr_D, 'Data branch Correlation results');
    xlabel(h_pwr_D, 'Time (s)');
    axis  (h_pwr_D, 'tight');
    
    hLegend = legend(h_pwr_D, '$\sqrt{I_{E}^2 + Q_{E}^2}$', ...
        '$\sqrt{I_{P}^2 + Q_{P}^2}$', ...
        '$\sqrt{I_{L}^2 + Q_{L}^2}$');
    
    %set interpreter from tex to latex. This will draw \sqrt correctly
    set(hLegend, 'Interpreter', 'Latex');

    plot(h_pwr_P, timeAxisInSeconds, ...
        [sqrt(trackResults(channelNr).Pilot_I_E.^2 + ...
        trackResults(channelNr).Pilot_Q_E.^2)', ...
        sqrt(trackResults(channelNr).Pilot_I_P.^2 + ...
        trackResults(channelNr).Pilot_Q_P.^2)', ...
        sqrt(trackResults(channelNr).Pilot_I_L.^2 + ...
        trackResults(channelNr).Pilot_Q_L.^2)'], ...
        '-','LineWidth',lw);
    
    grid  (h_pwr_P);
    title (h_pwr_P, 'Pilot branch Correlation results');
    xlabel(h_pwr_P, 'Time (s)');
    axis  (h_pwr_P, 'tight');
    
    hLegend = legend(h_pwr_P, '$\sqrt{I_{E}^2 + Q_{E}^2}$', ...
        '$\sqrt{I_{P}^2 + Q_{P}^2}$', ...
        '$\sqrt{I_{L}^2 + Q_{L}^2}$');
    
    %set interpreter from tex to latex. This will draw \sqrt correctly
    set(hLegend, 'Interpreter', 'Latex');
    
    %----- PLL discriminator filtered----------------------------------
    plot  (h_PLL_o, timeAxisInSeconds, ...
        trackResults(channelNr).pllDiscrFilt, 'b');
    
    grid  (h_PLL_o);
    axis  (h_PLL_o, 'tight');
    xlabel(h_PLL_o, 'Time (s)');
    ylabel(h_PLL_o, 'Amplitude');
    title (h_PLL_o, 'Filtered PLL discriminator');
    
    %----- DLL discriminator unfiltered--------------------------------
    plot  (h_DLL_f, timeAxisInSeconds, ...
        trackResults(channelNr).dllDiscr, 'r');
    
    grid  (h_DLL_f);
    axis  (h_DLL_f, 'tight');
    xlabel(h_DLL_f, 'Time (s)');
    ylabel(h_DLL_f, 'Amplitude');
    title (h_DLL_f, 'Raw DLL discriminator');
    
    %----- DLL discriminator filtered----------------------------------
    plot  (h_DLL_o, timeAxisInSeconds, ...
        trackResults(channelNr).dllDiscrFilt, 'b');
    
    grid  (h_DLL_o);
    axis  (h_DLL_o, 'tight');
    xlabel(h_DLL_o, 'Time (s)');
    ylabel(h_DLL_o, 'Amplitude');
    title (h_DLL_o, 'Filtered DLL discriminator');
    
    %----- Plot CNo----------------------------------
%     figure(channelNr +300);
%     clf(channelNr +300);
%     set(channelNr +300, 'Name', ['Channel ', num2str(channelNr), ...
%         ' (PRN ', ...
%         num2str(trackResults(channelNr).PRN), ...
%         ') CNo']);
%     plot(trackResults(channelNr).B2a_CNo,'mo-')
%     title('Data-channel C/No Estimation')
%     ylabel('dB-Hz')
%     xlabel('200msec (or as set in initSettings.m) epoch computation')
    end %if trackResults(channelNr).status == 'T' 
    

end % for channelNr = channelList
figure(999);  
set(999, 'Name', 'CN0 of All PRN');
plotIdx = false(size(channelList));
for channelNr = channelList
    if trackResults(channelNr).status == 'T'  
        plotIdx(channelNr) = true;
    end
end
RtrackResults = trackResults(plotIdx);
TotalChannel2Plot = sum(plotIdx);
ColorsArr = jet(TotalChannel2Plot);% color of each line
TimeScale = (0:length(trackResults(1).DataCNo)-1)*0.2;% each CN0 calculation interval 200msec;
strArr = cell(TotalChannel2Plot,1);
LegArr = [];
for channelNr = 1:TotalChannel2Plot
    LegArr=[LegArr,plot3(TimeScale,channelNr*ones(size(TimeScale)),...
        RtrackResults(channelNr).B2a_CNo,'Color',ColorsArr(channelNr,:),'LineWidth',1.5)];
    if channelNr==1,hold on;end
    strArr{channelNr} = sprintf('PRN:%d',RtrackResults(channelNr).PRN);
    title('Data-channel C/No Estimation')
    zlabel('dB-Hz')
    ylabel('Channel');
    xlabel('200msec (or as set in initSettings.m) epoch computation')
end
legend(LegArr,strArr,'fontsize',12,'location','bestoutside');
view(45,20);