function tests=test_pll_thermal_branch
tests=functiontests(localfunctions);
end

function testPilotLoopUsesPilotPower(testCase)
[tr,s]=fixture();
[~,sigma]=tr.estimateLoopNoise(s);
cn0=10^(47/10);
expected=180/pi*sqrt(30/cn0*(1+1/(2*0.001*cn0)));
verifyEqual(testCase,sigma,repmat(expected,1,5),'AbsTol',1e-12);
end

function testUnknownPilotPowerDoesNotBorrowDataPower(testCase)
[tr,s]=fixture(); tr.PilotCNo(:)=NaN;
[~,sigma]=tr.estimateLoopNoise(s);
verifyTrue(testCase,all(isnan(sigma)));
end

function [tr,s]=fixture()
tr=TrackResults2.createEmptyArray(1);
tr.B2a_CNo=50*ones(1,5); tr.PilotCNo=47*ones(1,5); tr.DataCNo=47*ones(1,5);
tr.cur_state=true(1,1000);
s=struct('CNoInterval',200,'pilotTRKflag',1,'longCoh_ms',1, ...
    'pllNoiseBandwidth_stab',30,'pllNoiseBandwidth_pull',50, ...
    'dllCorrelatorSpacing',0.5,'IFBandwidth',18e6,'codeFreqBasis',10.23e6);
end
