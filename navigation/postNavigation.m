function [navSolutions, eph] = postNavigation(trackResults, settings)
%Function calculates navigation solutions for the receiver (pseudoranges,
%positions). At the end it converts coordinates from the WGS84 system to
%the UTM, geocentric or any additional coordinate system.
%
%[navSolutions, eph] = postNavigation(trackResults, settings)
%
%   Inputs:
%       trackResults    - results from the tracking function (structure
%                       array).
%       settings        - receiver settings.
%   Outputs:
%       navSolutions    - contains measured pseudoranges, receiver
%                       clock error, receiver coordinates in several
%                       coordinate systems (at least ECEF and UTM).
%       eph             - received ephemerides of all SV (structure array).

%--------------------------------------------------------------------------
%                         CU Multi-GNSS SDR
% (C) Developed for BDS B2a SDR by Yafeng Li, Nagaraj C. Shivaramaiah 
% and Dennis M. Akos. 
% Based on the original framework for GPS C/A SDR by Darius Plausinaitis,
% Peter Rinder, Nicolaj Bertelsen and Dennis M. Akos
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
%$Id: postNavigation.m,v 1.1.2.22 2006/08/09 17:20:11 dpl Exp $

%% Check is there enough data to obtain any navigation solution
% It is necessary to have at least three messages (type 10, 11 and 
% anyone of 30-34) to find satellite coordinates. Then receiver 
% position can be found. The function requires at least 8 message.
% One message length is 6 seconds, therefore we need at least 18 sec long
% record (3 * 8 = 24 sec = 24000ms).
if (settings.msToProcess < 24000)
    % Show the error message and exit
    disp('Record is too short for B-CNAV2 navigation (<24 s). Exiting!');
    navSolutions = [];
    eph          = [];
    return
end

%% Normalize trackResults (struct / TrackResults2 handle) =================
% Refactor bridge: accept both legacy struct arrays and TrackResults2.
if ~isstruct(trackResults)
    if exist('trackResultsToStruct', 'file')
        trackResults = trackResultsToStruct(trackResults);
    elseif isa(trackResults, 'TrackResults2')
        tmp = trackResults;
        trackResults = repmat(struct(), 1, numel(tmp));
        for ii = 1:numel(tmp)
            trackResults(ii) = tmp(ii).toStruct();
        end
    end
end

nCh = numel(trackResults);
if nCh < 1
    disp('Empty trackResults. Exiting!');
    navSolutions = [];
    eph = [];
    return
end
% Align channel dimension with actual trackResults length
nChUse = min(settings.numberOfChannels, nCh);

%% Pre-allocate space
% Per-channel TOW segments (REACQ-aware). Each cell is a struct array with
% indexStart/indexEnd/subFrameStart/TOW so pre- and post-REACQ epochs both
% remain usable; LS runs whenever >=4 SVs have a valid segment at the epoch.
towSeg = cell(1, nChUse);
% Legacy scalars (first segment) kept for diagnostics / plots
subFrameStart  = inf(1, nChUse);
TOW  = inf(1, nChUse);

%--- Make a list of channels excluding not tracking channels ---------------
statusVec = arrayfun(@(x) char(string(x.status)), trackResults(1:nChUse), 'UniformOutput', false);
activeChnList = find(cellfun(@(s) ~isempty(s) && s(1) ~= '-', statusVec));

%% Decode ephemerides
% Pre-allocate eph for max PRN to avoid growth edge cases
maxPrn = 63;
eph = repmat(eph_structure_init(), 1, maxPrn);

for channelNr = activeChnList
    % Get PRN of current channel
    PRN = trackResults(channelNr).PRN;
    if isempty(PRN) || PRN < 1 || PRN > maxPrn
        activeChnList = setdiff(activeChnList, channelNr);
        continue;
    end
    
    fprintf('Decoding B-CNAV2 for PRN %02d of BDS-3 B2a signals -------------------- \n', PRN);

    %=== Decode ephemerides + multi-segment TOW (each lock run after REACQ)
    try
        [eph(PRN), segs, subFrameStart(channelNr), TOW(channelNr)] = ...
            decodeEphWithReacqResync(trackResults(channelNr));
        towSeg{channelNr} = segs;
    catch ME
        warning('postNavigation:DecodeFail', 'PRN %02d decode failed: %s', PRN, ME.message);
        activeChnList = setdiff(activeChnList, channelNr);
        continue;
    end

    if isempty(towSeg{channelNr})
        activeChnList = setdiff(activeChnList, channelNr);
        fprintf('  No valid TOW segment for PRN %02d — excluded.\n', PRN);
        continue;
    end

    %--- Exclude satellite if it does not have the necessary cnav data ----
    if (eph(PRN).idValid(1) ~= 10 || eph(PRN).idValid(2) ~= 11 ...
        || ~sum(eph(PRN).idValid(3:7) == (30:34)) )

        %--- Exclude channel from the list --------------------------------
        activeChnList = setdiff(activeChnList, channelNr);
        
        %--- Print CNAV decoding information for current PRN --------------
        if (eph(PRN).idValid(1) ~= 10)
            fprintf('  Message type 10 for PRN %02d not decoded.\n', PRN);
        end
        if (eph(PRN).idValid(2) ~= 11)
            fprintf('  Message type 11 for PRN %02d not decoded.\n', PRN);
        end
        if (~sum(eph(PRN).idValid(3:7) == (30:34)))
            fprintf('  None of message type 30-37 for PRN %02d decoded.\n', PRN);
        end
        fprintf('  Channel for PRN %02d excluded!!\n', PRN);
    else
        fprintf('  Three requisite messages for PRN %02d all decoded! (%d TOW segment(s))\n', ...
            PRN, numel(towSeg{channelNr}));
    end 
end %  channelNr = activeChnList

%% Check if the number of satellites is still above 3 =====================
if (isempty(activeChnList) || (size(activeChnList, 2) < 4))
    % Show error message and exit
    disp('Too few satellites with ephemeris data for postion calculations. Exiting!');
    navSolutions = [];
    return
end

%% Set measurement-time point and step  =====================================
% LS is epoch-wise: any epoch with >=4 SVs that have a valid TOW segment
% should attempt a fix. Therefore navigation time starts at the *earliest*
% first-segment preamble among ready SVs (not the max / last-REACQ only).
sampleStartCh = inf(1, nChUse);
sampleEndCh = inf(1, nChUse);
for channelNr = activeChnList
    absS = trackResults(channelNr).absoluteSample;
    segs = towSeg{channelNr};
    if isempty(segs)
        activeChnList = setdiff(activeChnList, channelNr);
        continue;
    end
    sf = segs(1).subFrameStart;
    if ~isfinite(sf) || sf < 1 || sf > numel(absS) || ~isfinite(absS(sf))
        activeChnList = setdiff(activeChnList, channelNr);
        continue;
    end
    sampleStartCh(channelNr) = absS(sf);
    % Prefer last finite absoluteSample (REACQ holes may leave NaN at end)
    lastFin = find(isfinite(absS), 1, 'last');
    if isempty(lastFin)
        activeChnList = setdiff(activeChnList, channelNr);
        continue;
    end
    sampleEndCh(channelNr) = absS(lastFin);
end
if numel(activeChnList) < 4
    disp('Too few satellites after sample alignment. Exiting!');
    navSolutions = [];
    return
end

% Earliest any SV can contribute; end when the shortest track ends
sampleStart = min(sampleStartCh(activeChnList)) + 1;
sampleEnd = min(sampleEndCh(activeChnList)) - 1;
fprintf(['Navigation window: sampleStart=%g sampleEnd=%g' ...
    ' (epoch-wise LS, multi-segment TOW; need >=4 SV/epoch)\n'], ...
    sampleStart, sampleEnd);
 
%--- Measurement step in unit of IF samples -------------------------------
measSampleStep = fix(settings.samplingFreq * settings.navSolPeriod/1000);

%---  Number of measurment point from measurment start to end ------------- 
measNrSum = fix((sampleEnd-sampleStart)/measSampleStep);

%% Initialization =========================================================
% Set the satellite elevations array to INF to include all satellites for
% the first calculation of receiver position. There is no reference point
% to find the elevation angle as there is no receiver position estimate at
% this point.
satElev  = inf(1, nChUse);

% Save the active channel list. The list contains satellites that are
% tracked and have the required ephemeris data. In the next step the list
% will depend on each satellite's elevation angle, which will change over
% time.  
readyChnList = activeChnList;

% Set local time to inf for first calculation of receiver position. After
% first fix, localTime will be updated by measurement sample step.
% Re-init after multi-SV REACQ gaps so post-REACQ TOW segments do not inherit
% a stale pre-REACQ receiver clock.
localTime = inf;
noFixStreak = 0;

% RAIM log pre-alloc
navSolutions.raim.mode = repmat({''}, 1, max(measNrSum, 1));
navSolutions.raim.residualRms = nan(1, max(measNrSum, 1));
navSolutions.raim.maxResidual = nan(1, max(measNrSum, 1));
navSolutions.raim.nExcluded = zeros(1, max(measNrSum, 1));
navSolutions.raim.excludedPRN = cell(1, max(measNrSum, 1));
navSolutions.raim.passed = false(1, max(measNrSum, 1));

%##########################################################################
%#   Do the satellite and receiver position calculations                  #
%##########################################################################

fprintf('Positions are being computed. Please wait... \n');
for currMeasNr = 1:measNrSum
   
    fprintf('Fix: Processing %02d of %02d \n', currMeasNr,measNrSum);
    
    %% Initialization of current measurement ==============================          
    % Exclude satellites, that are belove elevation mask 
    activeChnList = intersect(find(satElev >= settings.elevationMask), ...
                              readyChnList);

    % Save list of satellites used for position calculation
    navSolutions.PRN(activeChnList, currMeasNr) = ...
                                        [trackResults(activeChnList).PRN]; 

    % These two lines help the skyPlot function. The satellites excluded
    % do to elevation mask will not "jump" to possition (0,0) in the sky
    % plot.
    navSolutions.el(:, currMeasNr) = NaN(nChUse, 1);
    navSolutions.az(:, currMeasNr) = NaN(nChUse, 1);
                                     
    % Signal transmitting time of each channel at measurement sample location
    navSolutions.transmitTime(:, currMeasNr) = ...
                                         NaN(nChUse, 1);
    navSolutions.satClkCorr(:, currMeasNr) = ...
                                         NaN(nChUse, 1);                                                                  
    % Position index of current measurement time in IF signal stream
    % (in unit IF signal sample point)
    currMeasSample = sampleStart + measSampleStep*(currMeasNr-1);
                                                                      
%% Find pseudoranges ======================================================
    % Raw pseudorange = (localTime - transmitTime) * light speed (in m)
    % All output are 1 by settings.numberOfChannels columme vecters.
    [navSolutions.rawP(:, currMeasNr),transmitTime,localTime]=  ...
                     calculatePseudoranges(trackResults, towSeg, [], ...
                     currMeasSample,localTime,activeChnList, settings);
    % Save transmitTime
    navSolutions.transmitTime(activeChnList, currMeasNr) = ...
                                        transmitTime(activeChnList);

    % Drop REACQ / gap / no-segment channels this epoch (tt=inf)
    validPr = activeChnList(isfinite(transmitTime(activeChnList)));
    if numel(validPr) < numel(activeChnList) && (currMeasNr <= 3 || mod(currMeasNr, 50) == 0)
        fprintf('  Fix %d: %d/%d channels valid for PR (excluded REACQ/gap/no-TOW-seg)\n', ...
            currMeasNr, numel(validPr), numel(activeChnList));
    end

%% Find satellites positions and clocks corrections =======================
    % Epoch-wise LS: attempt whenever this epoch has >=4 usable SVs
    if numel(validPr) >= 4
        [satPositions, satClkCorr] = satpos1(transmitTime(validPr), ...
                                            [trackResults(validPr).PRN], eph);
        navSolutions.satClkCorr(validPr, currMeasNr) = satClkCorr;
    else
        satPositions = [];
        satClkCorr = [];
    end

%% Find receiver position =================================================
    if numel(validPr) >= 4
        noFixStreak = 0;

        %=== Calculate receiver position ==================================
        % Correct pseudorange for SV clock error
        clkCorrRawP = navSolutions.rawP(validPr, currMeasNr)' + ...
                                                   satClkCorr * settings.c;
        prnUsed = [trackResults(validPr).PRN];

        % Optional elev / C/N0 observation weights (settings.lsWeight)
        elForW = satElev(validPr);
        cnoForW = cnoAtMeasSample(trackResults, validPr, currMeasSample, settings);
        wObs = lsObservationWeights(elForW, cnoForW, settings);

        % Calculate receiver position (optional RAIM 1/2-SV FDE)
        useRaim = ~isfield(settings, 'raim') || ~isfield(settings.raim, 'enable') ...
            || logical(settings.raim.enable);
        try
            if useRaim
                [xyzdt, elAct, azAct, dopAct, raimInfo] = ...
                    raimLeastSquarePos(satPositions, clkCorrRawP, settings, prnUsed, wObs);
                navSolutions.el(validPr, currMeasNr) = elAct;
                navSolutions.az(validPr, currMeasNr) = azAct;
                navSolutions.DOP(:, currMeasNr) = dopAct(:);
                navSolutions.raim.mode{currMeasNr} = raimInfo.mode;
                navSolutions.raim.residualRms(currMeasNr) = raimInfo.residualRms;
                navSolutions.raim.maxResidual(currMeasNr) = raimInfo.maxResidual;
                nEx = 0;
                if isfield(raimInfo, 'nExcluded')
                    nEx = raimInfo.nExcluded;
                elseif isfield(raimInfo, 'excludedPRN')
                    nEx = numel(raimInfo.excludedPRN);
                end
                navSolutions.raim.nExcluded(currMeasNr) = nEx;
                if isfield(raimInfo, 'excludedPRN')
                    navSolutions.raim.excludedPRN{currMeasNr} = raimInfo.excludedPRN;
                end
                navSolutions.raim.passed(currMeasNr) = raimInfo.passed;
                if nEx > 0 && (currMeasNr <= 5 || mod(currMeasNr, 20) == 0 ...
                        || ~raimInfo.passed)
                    exPrn = [];
                    if isfield(raimInfo, 'excludedPRN'), exPrn = raimInfo.excludedPRN; end
                    fprintf('  RAIM fix %d: mode=%s exclude PRN%s rms=%.1fm maxRes=%.1fm passed=%d\n', ...
                        currMeasNr, raimInfo.mode, mat2str(exPrn), ...
                        raimInfo.residualRms, raimInfo.maxResidual, raimInfo.passed);
                end
            else
                [xyzdt, navSolutions.el(validPr, currMeasNr), ...
                 navSolutions.az(validPr, currMeasNr), ...
                 navSolutions.DOP(:, currMeasNr)] = ...
                    leastSquarePos(satPositions, clkCorrRawP, settings, wObs);
            end
        catch ME
            warning('postNavigation:LS', 'Fix %d LS/RAIM failed: %s', currMeasNr, ME.message);
            xyzdt = [NaN; NaN; NaN; NaN];
            navSolutions.DOP(:, currMeasNr) = zeros(5, 1);
        end

        %=== Save results ===========================================================
        % Receiver position in ECEF
        navSolutions.X(currMeasNr)  = xyzdt(1);
        navSolutions.Y(currMeasNr)  = xyzdt(2);
        navSolutions.Z(currMeasNr)  = xyzdt(3);
        earthR = norm(xyzdt(1:3));
        fixValid = all(isfinite(xyzdt(1:3))) && earthR > 5.5e6 && earthR < 7.5e6;
		% For first calculation of solution, clock error will be set 
        % to be zero
        if (currMeasNr == 1)
            navSolutions.dt(currMeasNr) = 0;  % in unit of (m)
        else
            navSolutions.dt(currMeasNr) = xyzdt(4);  
        end
		%=== Correct local time by clock error estimation =================
        if fixValid && isfinite(xyzdt(4))
            localTime = localTime - xyzdt(4)/settings.c;
        end
        navSolutions.localTime(currMeasNr) = localTime;
        
        % Save current measurement sample location 
        navSolutions.currMeasSample(currMeasNr) = currMeasSample;
        % Update the satellites elevations vector
        if fixValid
            satElev = abs(navSolutions.el(:, currMeasNr)');
        end

        %=== Correct pseudorange measurements for clocks errors ===========
        if fixValid
            rp = navSolutions.rawP(validPr, currMeasNr);
            navSolutions.correctedP(validPr, currMeasNr) = ...
                    rp(:) + satClkCorr(:) * settings.c - xyzdt(4);
        else
            navSolutions.correctedP(validPr, currMeasNr) = NaN;
        end
            
%% Coordinate conversion ==================================================
        if fixValid
            %=== Convert to geodetic coordinates ==============================
            try
                [navSolutions.latitude(currMeasNr), ...
                 navSolutions.longitude(currMeasNr), ...
                 navSolutions.height(currMeasNr)] = cart2geo(...
                                                    navSolutions.X(currMeasNr), ...
                                                    navSolutions.Y(currMeasNr), ...
                                                    navSolutions.Z(currMeasNr), ...
                                                    5);
            catch
                navSolutions.latitude(currMeasNr)  = NaN;
                navSolutions.longitude(currMeasNr) = NaN;
                navSolutions.height(currMeasNr)    = NaN;
            end

            lat = navSolutions.latitude(currMeasNr);
            lon = navSolutions.longitude(currMeasNr);
            if isfinite(lat) && isfinite(lon) && lat >= -80 && lat <= 84 ...
                    && lon >= -180 && lon <= 180
                %=== Convert to UTM coordinate system =============================
                navSolutions.utmZone = findUtmZone(lat, lon);
                [navSolutions.E(currMeasNr), ...
                 navSolutions.N(currMeasNr), ...
                 navSolutions.U(currMeasNr)] = cart2utm(xyzdt(1), xyzdt(2), ...
                                                        xyzdt(3), ...
                                                        navSolutions.utmZone);
            else
                % Invalid geodetic (bad geometry / PR alignment) — keep ECEF only
                navSolutions.latitude(currMeasNr)  = NaN;
                navSolutions.longitude(currMeasNr) = NaN;
                navSolutions.height(currMeasNr)    = NaN;
                navSolutions.E(currMeasNr) = NaN;
                navSolutions.N(currMeasNr) = NaN;
                navSolutions.U(currMeasNr) = NaN;
                if currMeasNr <= 3 || mod(currMeasNr, 20) == 0
                    fprintf('  Fix %d: invalid LLA (ECEF r=%.1f km) — skipped UTM\n', ...
                        currMeasNr, earthR/1e3);
                end
            end
        else
            navSolutions.latitude(currMeasNr)  = NaN;
            navSolutions.longitude(currMeasNr) = NaN;
            navSolutions.height(currMeasNr)    = NaN;
            navSolutions.E(currMeasNr) = NaN;
            navSolutions.N(currMeasNr) = NaN;
            navSolutions.U(currMeasNr) = NaN;
            if currMeasNr <= 3
                fprintf('  Fix %d: invalid ECEF r=%.1f km\n', currMeasNr, earthR/1e3);
            end
        end
        
    else
        %--- This epoch has <4 SVs with valid TOW segment / PR -----------
        noFixStreak = noFixStreak + 1;
        if noFixStreak >= 2
            % Gap / collective REACQ: drop stale localTime so next fix re-seeds
            localTime = inf;
        end
        if currMeasNr <= 5 || mod(currMeasNr, 50) == 0
            fprintf('   Measurement No. %d: only %d SV with valid PR (need >=4)\n', ...
                currMeasNr, numel(validPr));
        end

        navSolutions.X(currMeasNr)           = NaN;
        navSolutions.Y(currMeasNr)           = NaN;
        navSolutions.Z(currMeasNr)           = NaN;
        navSolutions.dt(currMeasNr)          = NaN;
        navSolutions.DOP(:, currMeasNr)      = zeros(5, 1);
        navSolutions.latitude(currMeasNr)    = NaN;
        navSolutions.longitude(currMeasNr)   = NaN;
        navSolutions.height(currMeasNr)      = NaN;
        navSolutions.E(currMeasNr)           = NaN;
        navSolutions.N(currMeasNr)           = NaN;
        navSolutions.U(currMeasNr)           = NaN;

        navSolutions.az(activeChnList, currMeasNr) = ...
                                             NaN(1, length(activeChnList));
        navSolutions.el(activeChnList, currMeasNr) = ...
                                             NaN(1, length(activeChnList));

    end % if numel(validPr) >= 4

    %=== Update local time by measurement  step  ====================================
    if isfinite(localTime)
        localTime = localTime + measSampleStep/settings.samplingFreq ;
    end

end %for currMeasNr...

% Attach multi-segment TOW metadata for diagnostics
navSolutions.towSeg = towSeg;
navSolutions.subFrameStart = subFrameStart;
navSolutions.TOW = TOW;
