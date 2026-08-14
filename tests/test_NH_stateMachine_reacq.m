function tests = test_NH_stateMachine_reacq
% Regression tests for consecutive low-C/N0 re-acquisition gating.
tests = functiontests(localfunctions);
end

function testThreeIndependentLowCnoUpdatesRequired(testCase)
nhsm = makeStateMachine();

nhsm.update(1, [20, 20], 200, 0);
verifyEqual(testCase, nhsm.STATE, 'INIT');
nhsm.update(1, [20, 20], 201, 0);
verifyEqual(testCase, nhsm.STATE, 'INIT');
nhsm.update(1, [20, 20], 400, 0);
verifyEqual(testCase, nhsm.STATE, 'INIT');
nhsm.update(1, [20, 20], 600, 0);

verifyEqual(testCase, nhsm.STATE, 'REACQ');
verifyTrue(testCase, nhsm.NeedACQ);
end

function testRecoveredCnoClearsConsecutiveCount(testCase)
nhsm = makeStateMachine();

nhsm.update(1, [20, 20], 200, 0);
nhsm.update(1, [20, 20], 400, 0);
nhsm.update(1, [30, 30], 600, 0);
nhsm.update(1, [20, 20], 800, 0);
nhsm.update(1, [20, 20], 1000, 0);
verifyEqual(testCase, nhsm.STATE, 'INIT');

nhsm.update(1, [20, 20], 1200, 0);
verifyEqual(testCase, nhsm.STATE, 'REACQ');
end

function nhsm = makeStateMachine()
settings = struct( ...
    'trackInit_MS', 1e6, ...
    'reEstimateMS', 1e6, ...
    'filter_pullinMS', 100, ...
    'TrkCN0Th', 25, ...
    'CNoInterval', 200, ...
    'reacqCnoConsecutive', 3, ...
    'reacqCnoRecoverDbHz', 28, ...
    'weilEstBuffLen', 200, ...
    'weilConfTh', 1.5, ...
    'pllOrder', 3, ...
    'pllNoiseBandwidth_stab', 30, ...
    'pllNoiseBandwidth_pull', 50, ...
    'longCoh_ms', 5, ...
    'FLL', struct('enable', false));
nhsm = NH_stateMachine(settings, []);
end
