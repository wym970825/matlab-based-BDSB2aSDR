function PWR = probeData2(settings,STEP,TOTAL,TYPE)
%Function plots raw data information: time domain plot, a frequency domain
%plot and a histogram.
%
%The function can be called in two ways:
%   probeData(settings)
% or
%   probeData(fileName, settings)
%
%   Inputs:
%       fileName        - name of the data file. File name is read from
%                       settings if parameter fileName is not provided.
%
%       settings        - receiver settings. Type of data file, sampling
%                       frequency and the default filename are specified
%                       here.

%--------------------------------------------------------------------------
%                           SoftGNSS v3.0
%
% Copyright (C) Dennis M. Akos
% Written by Darius Plausinaitis and Dennis M. Akos
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
% CVS record:
% $Id: probeData.m,v 1.1.2.7 2006/08/22 13:46:00 dpl Exp $
% _________________________________________________________________________

%% Check the number of arguments ==========================================
fileNameStr = fullfile(settings.filePath,settings.fileName);

%% Generate plot of raw data ==============================================
[fid, message] = fopen(fileNameStr, 'rb');

if (fid > 0)
    % Move the starting point of processing. Can be used to start the
    % signal processing at any point in the data record (e.g. for long
    % records).
%     fseek(fid, settings.skipNumberOfBytes, 'bof');

    % Find number of samples per spreading code
    if TYPE == 1 
        FS = 5000000;
        FC = 1.023e6;
        CL = 1023;
    else
        FS = 30.69e6;
        FC = 1.023e7;
        CL = 10230;
    end
    samplesPerCode = round(FS / ...
        (FC / CL));
    
    if (settings.fileType==1)
        dataAdaptCoeff=1;
    else
        dataAdaptCoeff=2;
    end
    % show 5 seconds power
    loopTimes = floor(TOTAL/STEP);
    MyTime = ((1:loopTimes) * STEP - STEP/2) * 1e-3;
    MyData = zeros(1,loopTimes);
    PWR = struct('MyTime',MyTime,'MyData',MyData);
    for lpCnt = 1:loopTimes
        try
            [data, count] = fread(fid, [1, dataAdaptCoeff*STEP*samplesPerCode], settings.dataType);
        catch
            % The file is to short
            error('Could not read enough data from the data file.');
        end
        if (count < dataAdaptCoeff * STEP * samplesPerCode)
        % The file is to short
            error('Could not read enough data from the data file.');
        end
        data = data - mean(data);
        pwr = mean(abs(data).^2);
        PWR.MyData(lpCnt) = pwr;
    end
    % close file;
    fclose(fid);
else
    %=== Error while opening the data file ================================
    error('Unable to read file %s: %s.', fileNameStr, message);
end % if (fid > 0)
