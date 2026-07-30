function build_mex()
%BUILD_MEX Compile P1/P2 MEX kernels for mexBaseFast branch.
    root = fileparts(fileparts(mfilename('fullpath')));
    mexDir = fullfile(root, 'mex');
    here = pwd;
    cleaner = onCleanup(@() cd(here));
    cd(mexDir);

    % -R2018a: interleaved complex API (mxComplexDouble / mxGetComplexDoubles)
    fprintf('Building correlateB2aMs_mex ...\n');
    mex('-O', '-R2018a', 'correlateB2aMs_mex.c', '-output', 'correlateB2aMs_mex');

    fprintf('Building pulseBlank_core_mex ...\n');
    mex('-O', '-R2018a', 'pulseBlank_core_mex.c', '-output', 'pulseBlank_core_mex');

    fprintf('Done. MEX files in %s\n', mexDir);
    addpath(mexDir);
end
