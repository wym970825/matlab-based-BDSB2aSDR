function ak = loadBaiduMapKey(varargin)
%LOADBAIDUMAPKEY Read Baidu Maps browser AK from config file.
%
%   ak = loadBaiduMapKey()
%   ak = loadBaiduMapKey(keyFile)
%
% Default path: <project>/config/BaidumapKey.txt
% File may be a single line of the key, or "ak=..." / comments with #.

    if nargin >= 1 && ~isempty(varargin{1})
        keyFile = char(varargin{1});
    else
        rootDir = fileparts(fileparts(mfilename('fullpath')));
        keyFile = fullfile(rootDir, 'config', 'BaidumapKey.txt');
    end

    if ~isfile(keyFile)
        error('loadBaiduMapKey:Missing', ...
            ['Baidu Map AK file not found: %s\n' ...
             'Copy config/BaidumapKey.example.txt to BaidumapKey.txt and paste your key.'], ...
            keyFile);
    end

    txt = fileread(keyFile);
    lines = regexp(txt, '\r\n|\n|\r', 'split');
    ak = '';
    for i = 1:numel(lines)
        s = strtrim(lines{i});
        if isempty(s) || startsWith(s, '#') || startsWith(s, '%')
            continue;
        end
        if contains(s, '=')
            parts = split(s, '=');
            s = strtrim(parts{end});
        end
        % strip quotes
        s = strrep(s, '"', '');
        s = strrep(s, '''', '');
        if ~isempty(s)
            ak = s;
            break;
        end
    end

    if isempty(ak)
        error('loadBaiduMapKey:Empty', 'No API key found in %s', keyFile);
    end
end
