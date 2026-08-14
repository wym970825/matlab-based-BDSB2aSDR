%INIT_B2A Compatibility entry (legacy name).
% Prefer:  results = run_B2a()
%
% This script mirrors the original init_B2a pipeline but uses the
% refactored modules and does NOT load stale trackingResults_01.mat.

setupPaths();
results = run_B2a(); %#ok<NASGU>
