function [pseudoranges,transmitTime,localTime] = ...
             calculatePseudoranges(trackResults,subFrameStart,TOW,currMeasSample, ...
             localTime,channelList, settings)
         
%calculatePseudoranges finds relative pseudoranges for all satellites
%listed in CHANNELLIST at the specified millisecond of the processed
%signal. The pseudoranges contain unknown receiver clock offset. It can be
%found by the least squares position search procedure. 
%
% [pseudoranges,transmitTime,localTime] = ...
%              calculatePseudoranges(trackResults,subFrameStart,TOW,currMeasSample, ...
%              localTime,channelList, settings)
%
%   Inputs:
%       trackResults    - output from the tracking function
%       subFrameStart   - the array contains positions of the first
%                       preamble in each channel. The position is ms count 
%                       since start of tracking. Corresponding value will
%                       be set to 0 if no valid preambles were detected in
%                       the channel: 
%                       1 by settings.numberOfChannels
%       TOW             - Time Of Week (TOW) of the first sub-frame in the bit
%                       stream (in seconds)
%       currMeasSample  - current measurement sample location(measurement time)
%       localTime       - local time(in GPST) at measurement time
%       channelList     - list of channels to be processed
%       settings        - receiver settings
%
%   Outputs:
%       pseudoranges    - relative pseudoranges to the satellites. 

%       transmitTime    - transmitting time of channels to be processed 
%                         corresponding to measurement time  
%       localTime       - local time(in GPST) at measurement time

%--------------------------------------------------------------------------
%--------------------------------------------------------------------------
%                         CU Multi-GNSS SDR  
% (C) Written by Yafeng Li, Nagaraj C. Shivaramaiah and Dennis M. Akos
% based on the original work by Darius Plausinaitis,
% Peter Rinder, Nicolaj Bertelsen and Dennis M. Akos
%--------------------------------------------------------------------------
%
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

% CVS record:
% $Id: calculatePseudoranges.m,v 1.1.2.18 2006/08/09 17:20:11 dpl Exp $
    
% Transmitting Time of all channels at current measurement sample location
transmitTime = inf(1, settings.numberOfChannels);

% This is used to accelerate the search process
persistent searchIndex;
if isempty(searchIndex) || (localTime == inf)
    searchIndex = ones(1, settings.numberOfChannels);
end
%--- For all channels in the list ... 
for channelNr = channelList
    absS = trackResults(channelNr).absoluteSample;
    nAbs = numel(absS);
    if nAbs < 2 || ~isfinite(subFrameStart(channelNr)) || ~isfinite(TOW(channelNr))
        transmitTime(channelNr) = inf;
        continue;
    end
    % Clamp search start into range (ring/chunk edges + REACQ recovery)
    i0 = searchIndex(channelNr);
    if ~isfinite(i0) || i0 < 1
        i0 = 1;
    end
    i0 = min(i0, nAbs);

    % Find last index with finite absoluteSample <= currMeasSample
    index = i0;
    for ii = i0:nAbs
        a = absS(ii);
        if ~isfinite(a)
            continue; % skip REACQ holes that still slipped through
        end
        if a > currMeasSample
            break
        end
        index = ii;
    end
    searchIndex(channelNr) = max(1, index);

    if index < 1 || index > nAbs || ~isfinite(absS(index))
        transmitTime(channelNr) = inf;
        continue;
    end
    % Exclude REACQ / no-correlation ticks from PR (trk_state==9)
    if isfield(trackResults, 'trk_state') ...
            && numel(trackResults(channelNr).trk_state) >= index ...
            && trackResults(channelNr).trk_state(index) == 9
        transmitTime(channelNr) = inf;
        continue;
    end

    cf = trackResults(channelNr).codeFreq(index);
    if ~isfinite(cf) || cf <= 0
        cf = settings.codeFreqBasis;
    end
    codePhaseStep = cf / settings.samplingFreq;

    % Code phase from start of a PRN code to current measurement sample
    codePhase = trackResults(channelNr).remCodePhase(index) +  ...
        codePhaseStep * (currMeasSample - absS(index));

    % Transmit time: TOW anchors subFrameStart (post-REACQ re-synced in nav)
    transmitTime(channelNr) = (codePhase/settings.codeLength + index - ...
        subFrameStart(channelNr)) * settings.codeLength / ...
        settings.codeFreqBasis + TOW(channelNr);
end

% At first time of fix, local time is initialized by transmitTime and 
% settings.startOffset
if (localTime == inf)
    maxTime   = max(transmitTime(channelList));
    localTime = maxTime + settings.startOffset/1000;  
end

%--- Convert travel time to a distance ------------------------------------
pseudoranges = (localTime - transmitTime) * settings.c;
% Invalid / REACQ channels keep NaN (not Inf) for downstream LS masks
badTt = ~isfinite(transmitTime);
pseudoranges(badTt) = NaN;

