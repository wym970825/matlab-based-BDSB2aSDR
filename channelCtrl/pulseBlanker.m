classdef pulseBlanker < handle
    % pulseBlanker do pulse blanking(PB)
    % Usage:
    %   pb = pulseBlanker(settings);
    %   signal_blanked = pb.mitigate(signal);


    properties
        EPWR_ttl double           = 0;        % read from settings, current INIT duration
        EPWR_Pfa double           = 0;        % read from settings, false alert prob.
        EPWR_th  double           = 0;        % ms, current LONG duration
        UseStatic logical         = false;    % bool, determine if a static threshold is selected
        Th_static double          = 0;        % the default threshold
        % record duty cycle
        PDC double = 0;  % duty cycle of Pulse blanker
        Ppre double = 0; % power before blanker in digital domain
        Ppost double = 0; % power after blanker in digital domain
    end

    properties (Access = private)
        % if PwrEstTime = 0, recalculate the threshold
        PwrEstTime double = 0;
        mean2Sigma double = sqrt(2/pi);
        sigma2Th_complex double = 3;
        sigma2Th_real double = 3;
    end
    methods
        function obj = pulseBlanker(settings)
            % % Example
            % settings.EnablePB = true;
            % % PB settings
            % settings.PB_settings.falseAlert = 1e-4; % For threshold calculating
            % settings.PB_settings.Th_TTL = 1e3; % [ms] The threshold may
            %                                    % not be calculated on each cycle,
            % forced to calculate the threshold after initial
            obj.PwrEstTime = 0;
            obj.PDC = 0;
            obj.Ppre = 0;
            obj.Ppost = 0;

            if isfield(settings,'PB_settings')
                % Threshold time to Live
                if isfield(settings.PB_settings,'Th_TTL')
                    obj.EPWR_ttl = settings.PB_settings.Th_TTL;
                else
                    obj.EPWR_ttl = 100;
                end
                % Threshold time to Live
                if isfield(settings.PB_settings,'falseAlert')
                    obj.EPWR_Pfa = settings.PB_settings.falseAlert;
                else
                    obj.EPWR_Pfa = 1e-4;
                end
                % if PB use a static threshold
                if isfield(settings.PB_settings,'UseStatic')
                    obj.UseStatic = settings.PB_settings.UseStatic;
                else
                    obj.UseStatic = false;
                end
                % static threshold
                if isfield(settings.PB_settings,'Th_static')
                    obj.Th_static = settings.PB_settings.Th_static;
                else
                    obj.Th_static = inf;
                end
            else
                obj.EPWR_Pfa = 1e-4;
                obj.EPWR_ttl = 100;
            end
            obj.sigma2Th_complex = sqrt(-2 * log(obj.EPWR_Pfa));
            try
                obj.sigma2Th_real = norminv(1-obj.EPWR_Pfa/2);
            catch
                obj.sigma2Th_real = sqrt(2) * erfinv(1-obj.EPWR_Pfa); % alternative
            end

            % constructor done
        end


        function signal = mitigate(obj, signal)
            % update
            % signal: IF complex data or IF
            %% signal in complex,
            % use rayleigh model
            if isempty(signal)
                return;
            end
            %------------Pulse blnking-----------------------%
            if ~obj.UseStatic
                if ~isreal(signal)
                    if ~ obj.PwrEstTime
                        obj.EPWR_th = mean(abs(signal)) * obj.mean2Sigma *...
                            obj.sigma2Th_complex;
                    end
                    obj.PwrEstTime = obj.PwrEstTime + 1;
                    if obj.PwrEstTime >= obj.EPWR_ttl
                        obj.PwrEstTime = 0;
                    end
                else
                    if ~ obj.PwrEstTime
                        obj.EPWR_th = std(signal) * obj.sigma2Th_real;
                    end
                    obj.PwrEstTime = obj.PwrEstTime + 1;
                    if obj.PwrEstTime >= obj.EPWR_ttl
                        obj.PwrEstTime = 0;
                    end
                end
                BlankIdx = (abs(signal)>obj.EPWR_th);
            else
                BlankIdx = (abs(signal)>obj.Th_static);
            end
            obj.Ppre = 10*log10(mean(abs(signal).^2));
            obj.PDC = mean(BlankIdx);
            signal(BlankIdx) = 0;
            obj.Ppre = 10*log10(mean(abs(signal).^2));
            % if
        end % update
        function varargout = f_mitigate(obj, signal, k, gain, fs)
            % mitigation with a debug figure
            % signal, pre-blanking signal
            % k, rffe scale k [dB]
            % gain, rffe gain [dB]
            % fs, sampling rate
            if isempty(signal)
                return;
            end
            signal_post  = signal;
            if ~obj.UseStatic
                if ~isreal(signal_post)
                    if ~ obj.PwrEstTime
                        obj.EPWR_th = mean(abs(signal_post)) * obj.mean2Sigma *...
                            obj.sigma2Th_complex;
                    end
                    obj.PwrEstTime = obj.PwrEstTime + 1;
                    if obj.PwrEstTime >= obj.EPWR_ttl
                        obj.PwrEstTime = 0;
                    end
                else
                    if ~ obj.PwrEstTime
                        obj.EPWR_th = std(signal_post) * obj.sigma2Th_real;
                    end
                    obj.PwrEstTime = obj.PwrEstTime + 1;
                    if obj.PwrEstTime >= obj.EPWR_ttl
                        obj.PwrEstTime = 0;
                    end
                end
                BlankIdx = (abs(signal_post)>obj.EPWR_th);
                obj.PDC = mean(BlankIdx);
                signal_post(BlankIdx) = 0;
            else
                BlankIdx = (abs(signal_post)>obj.Th_static);
                obj.PDC = mean(BlankIdx);
                signal_post(BlankIdx) = 0;
            end
            fig = figure('color','w','Units','centimeters','Position', [2,2,10,6]);
            ax = newplot(); hold on; grid on; box on;
            scale = + k + gain - 10*log10(fs);
            t_axis = (1:numel(signal))/fs * 1e3; % time axis in [ms]
            tLim = [t_axis(1),t_axis(end)]; % time limit(X limit)
            
            pwr_pre  = 10*log10(abs(signal).^2) + scale;
            pwr_post = 10*log10(abs(signal_post).^2) + scale;
            if ~obj.UseStatic
                threshold = 20*log10(obj.EPWR_th) + scale;
            else
                threshold = 20*log10(obj.Th_static) + scale;
            end
            l1 = plot(ax,t_axis, pwr_pre,'Color','b','LineWidth',0.5);
            l2 = plot(ax,t_axis, pwr_post,'Color','r','LineWidth',0.5);
            l3 = plot(ax,tLim, [threshold,threshold],...
                'Color','k','LineWidth',1,'LineStyle','--');
            % power limit(i.e., YLim in [dBm])
            pLim = [floor(min(pwr_post(isfinite(pwr_post)))/10)*10,...
                ceil(max(pwr_pre(isfinite(pwr_pre)))/10)*10];
            set(gca,'GridAlpha',0.4,'XLim',tLim,'YLim',pLim,'FontName',...
                'Times New Roman','FontSize',10.5);
            xlabel(ax,'T (ms)','FontName','Times New Roman','FontSize',10.5);
            ylabel(ax,'Power (dBm)','FontName','Times New Roman','FontSize',10.5);
            legend(ax,[l1,l2,l3],{'Input','Output','Threshold'},...
                'FontName','Times New Roman','FontSize',9,...
                'Orientation','horizontal','Location','south',...
                'BackgroundAlpha',0.8,'IconColumnWidth',10);
            if nargout == 1
                varargout{1} = signal_post;
            elseif nargout == 2
                varargout{1} = signal_post;
                varargout{2} = fig;
            else
                error('Too much arg. to output');
            end
        end
    end % methods
end % classdef
