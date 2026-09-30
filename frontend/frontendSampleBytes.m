function bytes=frontendSampleBytes(dataType,fileType)
%FRONTENDSAMPLEBYTES Preserve legacy fread aliases for off/PB formats.
    name=lower(strtrim(char(dataType))); name=regexprep(name,'^\*','');
    parts=strsplit(name,'=>'); name=strtrim(parts{1});
    switch name
        case {'int8','uint8','char','schar','uchar','logical','integer*1'}, bytes=1;
        case {'int16','uint16','short','ushort','integer*2'}, bytes=2;
        case {'int32','uint32','single','float','float32','integer*4','real*4'}, bytes=4;
        case {'int64','uint64','double','float64','integer*8','real*8'}, bytes=8;
        otherwise, error('Frontend:UnsupportedFormat','Unsupported dataType: %s',name);
    end
    assert(ismember(fileType,[1 2]),'Frontend:UnsupportedFormat','fileType must be real (1) or IQ (2).');
    bytes=bytes*fileType;
end
