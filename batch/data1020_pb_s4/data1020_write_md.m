function data1020_write_md(file,t,titleText)
fid=fopen(file,'w','n','UTF-8');
fprintf(fid,'# %s\n\n',titleText);
names=string(t.Properties.VariableNames);
fprintf(fid,'| %s |\n',join(names,' | '));
fprintf(fid,'| %s |\n',join(repmat("---",size(names)),' | '));
for i=1:height(t)
    values=strings(1,width(t));
    for j=1:width(t)
        v=t{i,j};
        if iscell(v), v=v{1}; end
        if isdatetime(v), v.Format="yyyy-MM-dd'T'HH:mm:ss.SSSXXX"; end
        if isnumeric(v)
            values(j)=join(compose('%.12g',v),', ');
        else
            values(j)=join(string(v),', ');
        end
    end
    values(ismissing(values))="—";
    values=replace(replace(values,"|","/"),newline," ");
    fprintf(fid,'| %s |\n',join(values,' | '));
end
fclose(fid);
end
