classdef IFSource < handle
%IFSOURCE Private IF file, logical complex-sample cursor, and one frontend.
% readRange has no cursor side effect; read/seekAbs/tellLogical use physical
% sample indices, never the underlying file position after halo reads.
    properties (SetAccess=private)
        Settings
        Mode
        Info
        BytesPerSample
        SampleCount
        Halo = 0
        Mitigator
    end
    properties (Access=private)
        Fid = -1
        Cursor = 0
        ValuesPerSample
    end
    methods
        function obj = IFSource(settings,stage)
            if nargin<2, stage='tracking'; end
            settings = resolveFrontendSettings(settings);
            obj.Settings=settings; obj.Mode=settings.Frontend.mode;
            obj.Info=settings.Frontend; obj.Info.stage=stage;
            obj.ValuesPerSample=settings.fileType;
            assert(ismember(obj.ValuesPerSample,[1 2]),'Frontend:UnsupportedFormat','fileType must be 1 or 2.');
            obj.BytesPerSample=frontendSampleBytes(settings.dataType,settings.fileType);
            target=fullfile(settings.filePath,settings.fileName); info=dir(target);
            assert(~isempty(info),'IFSource:MissingFile','IF file not found: %s',target);
            if strcmp(obj.Mode,'tf_v1')
                assert(mod(info.bytes,obj.BytesPerSample)==0,'IFSource:IncompleteIQ','File ends inside a sample.');
            end
            % Legacy off/PB terminate on the last complete epoch, tolerating a
            % truncated final scalar exactly as the original fread loop did.
            obj.SampleCount=floor(info.bytes/obj.BytesPerSample);
            obj.Mitigator=createInterferenceMitigator(settings,stage);
            if strcmp(obj.Mode,'tf_v1')
                obj.Halo=obj.Mitigator.Config.H;
                obj.Info=obj.Mitigator.Info; obj.Info.stage=stage;
            end
            machine='native';
            if isfield(settings,'machineFormat') && ~isempty(settings.machineFormat), machine=settings.machineFormat; end
            if isfield(settings,'skipNumberOfBytes')
                assert(mod(settings.skipNumberOfBytes,obj.BytesPerSample)==0, ...
                    'IFSource:UnalignedOffset','skipNumberOfBytes splits a complete sample.');
                obj.seekAbs(settings.skipNumberOfBytes/obj.BytesPerSample);
            end
            [obj.Fid,msg]=fopen(target,'rb',machine);
            assert(obj.Fid>0,'IFSource:OpenFailed','Cannot open IF: %s',msg);
        end

        function delete(obj)
            if obj.Fid>0, fclose(obj.Fid); obj.Fid=-1; end
        end

        function n=tellLogical(obj), n=obj.Cursor; end

        function seekAbs(obj,n)
            IFSource.checkIndex(n); obj.Cursor=n;
        end

        function [data,meta]=read(obj,count)
            [data,meta]=obj.readRange(obj.Cursor,count);
            obj.Cursor=obj.Cursor+numel(data);
        end

        function [data,meta]=readRange(obj,start,count)
            IFSource.checkIndex(start); IFSource.checkIndex(count);
            count=max(0,min(count,obj.SampleCount-start));
            if strcmp(obj.Mode,'tf_v1') && count>0
                left=max(0,start-obj.Halo); right=min(obj.SampleCount,start+count+obj.Halo);
                raw=obj.readRawRange(left,right-left);
                [data,meta]=obj.Mitigator.applyRange(raw,left,start,count);
            else
                data=obj.readRawRange(start,count);
                meta=struct('logicalStartAbs',start,'logicalCount',numel(data), ...
                    'valid',true(size(data)),'validCount',numel(data),'boundaryFlag',false, ...
                    'detectorDuty',0,'meanWeight',0,'meanWeightSquared',0,'weightSupportFraction',0);
                if strcmp(obj.Mode,'pb') && ~isempty(data)
                    data=obj.Mitigator.mitigate(data);
                    meta.detectorDuty=obj.Mitigator.PDC; meta.meanWeight=obj.Mitigator.PDC;
                    meta.meanWeightSquared=obj.Mitigator.PDC; meta.weightSupportFraction=obj.Mitigator.PDC;
                end
            end
            meta.Ppre=NaN; meta.Ppost=NaN; meta.eta=NaN;
            if strcmp(obj.Mode,'pb') && ~isempty(data)
                meta.Ppre=obj.Mitigator.Ppre; meta.Ppost=obj.Mitigator.Ppost; meta.eta=obj.Mitigator.PDC;
            end
        end

        function data=readRawRange(obj,start,count)
            IFSource.checkIndex(start); IFSource.checkIndex(count);
            count=max(0,min(count,obj.SampleCount-start));
            if count==0, data=zeros(1,0); return; end
            assert(fseek(obj.Fid,start*obj.BytesPerSample,'bof')==0,'IFSource:SeekFailed','IF seek failed.');
            raw=fread(obj.Fid,[obj.ValuesPerSample count],obj.Settings.dataType);
            assert(numel(raw)==obj.ValuesPerSample*count,'IFSource:ShortRead','IF file changed or read failed.');
            if obj.ValuesPerSample==2
                data=double(raw(1,:))+1i*double(raw(2,:));
            else
                data=double(raw(1,:));
            end
        end
    end
    methods (Static,Access=private)
        function checkIndex(n)
            assert(isnumeric(n) && isscalar(n) && isfinite(n) && n>=0 && n==round(n), ...
                'IFSource:InvalidRange','Sample index/count must be a nonnegative integer.');
        end
    end
end
