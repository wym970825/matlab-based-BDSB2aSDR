function tests = test_algorithm_diagnostics
% Numerical/physical boundary tests discovered during five-case data review.
tests = functiontests(localfunctions);
end

function testInvalidVsmMomentIsNotAValidCarrier(testCase)
    I=repmat([0 0 0 10],1,50); Q=zeros(size(I));
    cno=Calc_CNo_PLD(prompts(I,Q), config(numel(I)), numel(I));
    verifyTrue(testCase, all(isinf(cno) & cno<0));
end

function testZeroSignalHasZeroCarrierPower(testCase)
    cno=Calc_CNo_PLD(prompts(zeros(1,200),zeros(1,200)), config(200), 200);
    verifyTrue(testCase, all(isinf(cno) & cno<0));
end

function testNonfiniteWindowIsUnavailable(testCase)
    I=ones(1,200); I(50)=NaN;
    cno=Calc_CNo_PLD(prompts(I,zeros(1,200)), config(200), 200);
    verifyTrue(testCase, all(isnan(cno)));
end

function testHealthyCarrierEstimatePreserved(testCase)
    previous=rng; cleanup=onCleanup(@() rng(previous)); rng(20);
    N=200000; I=10+randn(1,N); Q=randn(1,N);
    cno=Calc_CNo_PLD(prompts(I,Q), config(N), N);
    % Signal=100, complex noise=2; 1-ms coherent SNR=50.
    expected=10*log10(50/0.001);
    verifyEqual(testCase,cno(1),expected,'AbsTol',0.1);
    verifyEqual(testCase,cno(3),cno(1)+10*log10(2),'AbsTol',1e-10);
end

function testDopUsesLocalHorizontalAndVerticalAxes(testCase)
    pos=[6378137;0;0];
    az=deg2rad([0 55 100 155 205 250 300 345]);
    el=deg2rad([10 30 60 80 25 45 65 15]);
    enu=[cos(el).*sin(az);cos(el).*cos(az);sin(el)];
    % At lat=lon=0, ECEF X is up, Y east, Z north.
    sat=pos+21e6*enu([3 1 2],:);
    obs=sqrt(sum((sat-pos).^2,1));
    s=struct('c',299792458,'useTropCorr',false);
    [~,elOut,azOut,dop]=leastSquarePos(sat,obs,s);
    elOut=deg2rad(elOut(:)); azOut=deg2rad(azOut(:));
    G=[-cos(elOut).*sin(azOut),-cos(elOut).*cos(azOut),-sin(elOut),ones(8,1)];
    Q=(G.'*G)\eye(4);
    expected=[sqrt(trace(Q)),sqrt(trace(Q(1:3,1:3))), ...
        sqrt(Q(1,1)+Q(2,2)),sqrt(Q(3,3)),sqrt(Q(4,4))];
    verifyEqual(testCase,dop,expected,'AbsTol',1e-8);
end

function q=prompts(I,Q)
q=struct('I_P',I,'Q_P',Q,'Pilot_I_P',I,'Pilot_Q_P',Q);
end

function s=config(N)
s=struct('intTime',0.001,'CNoInterval',N,'pilotTRKflag',1);
end
