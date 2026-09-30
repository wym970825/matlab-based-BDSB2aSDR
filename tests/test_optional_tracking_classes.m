function tests = test_optional_tracking_classes
    tests = functiontests(localfunctions);
end

function testIakfUsesCurrentSettings(testCase)
    settings = struct('intTime', 0.001, 'KF', struct('qJerk', 3.5));
    filter = CarrierKF2_IAKF(settings);
    filter.predict();
    filter.update([0.01; 0.1], 45, 0.001);
    verifyClass(testCase, filter, 'CarrierKF2_IAKF');
    verifyTrue(testCase, all(isfinite(filter.x)));
    verifyTrue(testCase, all(isfinite(filter.P(:))));
end

function testConkerVariantCanBeConstructedAndReset(testCase)
    calc = scint_calculator_conkerR(struct('intTime', 0.001));
    verifyClass(testCase, calc, 'scint_calculator_conkerR');
    calc.reset();
    verifyTrue(testCase, isstruct(calc.getResult()));
end
