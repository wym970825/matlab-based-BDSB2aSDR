function tests = test_scint_intensity_definition
tests=functiontests(localfunctions);
end

function testNoOutputBeforeWarmupAndFullWindow(testCase)
calc=scint_calculator(settings(10000));
for k=1:8000, calc.push(1,0,0,[],true,50); end
verifyFalse(testCase,calc.getResult().valid);
for k=8001:12000, calc.push(1,0,0,[],true,50); end
r=calc.getResult();
verifyTrue(testCase,r.valid);
verifyLessThan(testCase,r.S4_ori,1e-3);
calc.reset();
verifyFalse(testCase,calc.getResult().valid);
end

function testKnownSinusoidalIntensity(testCase)
calc=scint_calculator(settings(10000));
m=0.6;
for k=1:20000
    intensity=1+m*sin(2*pi*10*k/1000);
    calc.push(sqrt(intensity),0,0,[],true,100);
end
r=calc.getResult();
verifyTrue(testCase,r.valid);
verifyEqual(testCase,r.S4_ori,m/sqrt(2),'AbsTol',0.005);
end

function testNativeOneMsNoiseTerm(testCase)
previous=rng; cleanup=onCleanup(@() rng(previous)); rng(23);
calc=scint_calculator(settings(10000));
I=10+randn(1,22000); Q=randn(size(I));
cn0=10*log10(50/0.001);
for k=1:numel(I), calc.push(I(k),Q(k),0,[],true,cn0); end
r=calc.getResult();
verifyEqual(testCase,r.S4_corr,sqrt(2/50+1/50^2),'AbsTol',1e-12);
verifyEqual(testCase,r.S4_ori,r.S4_corr,'AbsTol',0.025);
end

function s=settings(warmup)
s=struct('intTime',0.001,'longCoh_ms',1,'scint_updateMs',1000, ...
    'scint_bufLen',2000,'scint_fCutoff',1, ...
    'KF',struct('scintWarmup_ms',warmup));
end
