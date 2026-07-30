function [fid, dataAdaptCoeff] = openIfFile(settings)
%OPENIFFILE Open IF binary file and seek to configured start.

    targetfile = fullfile(settings.filePath, settings.fileName);
    fprintf('\tOpening IF file: %s\n', targetfile);
    [fid, message] = fopen(targetfile, 'rb');
    if fid <= 0
        error('openIfFile:CannotOpen', 'Unable to read file %s: %s.', ...
            settings.fileName, message);
    end

    if settings.fileType == 1
        dataAdaptCoeff = 1;
    else
        dataAdaptCoeff = 2;
    end

    status = fseek(fid, settings.skipNumberOfBytes, 'bof');
    if status ~= 0
        fclose(fid);
        error('openIfFile:SeekFailed', 'fseek failed for skipNumberOfBytes=%d', ...
            settings.skipNumberOfBytes);
    end
    fprintf('\tIF file opened successfully.\n');
end
