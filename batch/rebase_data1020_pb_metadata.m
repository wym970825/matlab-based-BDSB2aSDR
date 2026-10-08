function rebase_data1020_pb_metadata(manifestPath)
%REBASE_DATA1020_PB_METADATA Update portable UI metadata after directory moves.
% Full scientific MATs and per-PRN tracking arrays remain byte-for-byte intact.
    m=jsondecode(fileread(manifestPath));
    for k=1:numel(m.entries)
        e=m.entries(k); dst=e.pbDir;
        source=fullfile(dst,'ui_results.mat');
        backup=fullfile(dst,'ui_results_before_relocation.mat');
        if ~isfile(backup), copyfile(source,backup); end
        S=load(backup,'results'); results=S.results;
        s=results.settings; [~,name]=fileparts(dst);
        s.resultRoot=dst; s.outDir=dst; s.tempdataSvPth=fullfile(dst,'temp'); s.tag=name;
        results.settings=s; writeUiResultsMat(source,results);
        writeJson(fullfile(dst,'effective_settings.json'),s);
        paths={'ui_config.json','report.json'};
        for j=1:numel(paths)
            path=fullfile(dst,paths{j});
            oldPath=fullfile(dst,['before_relocation_' paths{j}]);
            if ~isfile(oldPath), copyfile(path,oldPath); end
            text=fileread(oldPath);
            value=jsondecode(text);
            value=replacePaths(value,e.originalRunDir,dst);
            if isfield(value,'tag'), value.tag=name; end
            writeJson(path,value);
        end
        writeJson(fullfile(dst,'relocation.json'),struct('originalRunDir',e.originalRunDir, ...
            'currentRunDir',dst,'utcStart',e.utcStart,'station',e.station, ...
            'stationMatchConfidence',e.stationMatchConfidence, ...
            'scientificArraysUnchanged',true, ...
            'note','Only lightweight UI metadata and replay JSON paths were rebased. Full scientific MAT archives retain original run metadata.'));
    end
end

function out=replacePaths(value,old,new)
    out=value;
    if isstruct(value)
        names=fieldnames(value);
        for j=1:numel(value)
            for k=1:numel(names), out(j).(names{k})=replacePaths(value(j).(names{k}),old,new); end
        end
    elseif iscell(value)
        for k=1:numel(value), out{k}=replacePaths(value{k},old,new); end
    elseif ischar(value)
        out=strrep(value,old,new);
        out=strrep(out,strrep(old,'\','/'),strrep(new,'\','/'));
    end
end

function writeJson(path,value)
    fid=fopen(path,'w','n','UTF-8'); assert(fid>0);
    cleanup=onCleanup(@()fclose(fid)); fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end
