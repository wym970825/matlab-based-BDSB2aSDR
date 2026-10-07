function results = acquisitionParallel(data, settings)
%ACQUISITIONPARALLEL Run the unchanged acquisition kernel independently per PRN.
% Opt-in orchestration only: each worker receives the same preprocessed input.
% Candidate order and all coarse/fine diagnostics match the serial kernel.
    prns = settings.acqSatelliteList(:).';
    cap = 6;
    if isfield(settings,'parMaxWorkers'), cap=settings.parMaxWorkers; end
    nWorkers = 0;
    if numel(prns)>1, nWorkers=ensureTrackParPool(min(cap,numel(prns))); end
    if nWorkers<2
        results=acquisition_robust_v2fft(data,settings,'STA','INIT','USEFFT',false);
        return
    end
    fprintf('Acquisition: %d independent PRNs, %d process workers.\n',numel(prns),nWorkers);
    parts=cell(1,numel(prns));
    parfor k=1:numel(prns)
        one=settings;
        one.acqSatelliteList=prns(k);
        parts{k}=acquisition_robust_v2fft(data,one,'STA','INIT','USEFFT',false);
    end
    results=parts{1};
    names=fieldnames(results);
    for k=1:numel(names)
        name=names{k};
        values=cellfun(@(part) part.(name),parts,'UniformOutput',false);
        if strcmp(name,'coarseNoncohMs')
            assert(all(cellfun(@(v) isequal(v,values{1}),values)), ...
                'acquisitionParallel:Metadata','Inconsistent integration lengths.');
        else
            results.(name)=cat(2,values{:});
        end
    end
    assert(isequal(results.satelliteList,prns),'acquisitionParallel:Order','PRN order changed.');
end
