function build_mex()
%BUILD_MEX Compile P1/P2 MEX kernels for mexBaseFast branch.
    root = fileparts(fileparts(mfilename('fullpath')));
    mexDir = fullfile(root, 'mex');
    here = pwd;
    cleaner = onCleanup(@() cd(here));
    cd(mexDir);

    % -R2018a: interleaved complex API (mxComplexDouble / mxGetComplexDoubles)
    % MSVC: enable SSE2 (default x64) and favor speed
    fprintf('Building correlateB2aMs_mex (LUT+SSE2) ...\n');
    if ispc
        mex('-O', '-R2018a', 'COMPFLAGS="$COMPFLAGS /O2 /arch:SSE2"', ...
            'correlateB2aMs_mex.c', '-output', 'correlateB2aMs_mex');
    else
        mex('-O', '-R2018a', 'CFLAGS="$CFLAGS -O3 -msse2"', ...
            'correlateB2aMs_mex.c', '-output', 'correlateB2aMs_mex');
    end

    fprintf('Building pulseBlank_core_mex ...\n');
    mex('-O', '-R2018a', 'pulseBlank_core_mex.c', '-output', 'pulseBlank_core_mex');

    fprintf('Done. MEX files in %s\n', mexDir);
    addpath(mexDir);
end
