function tests=test_config_entrypoints
%TEST_CONFIG_ENTRYPOINTS Configuration transport, precedence and replay checks.
    tests=functiontests(localfunctions);
end

function setupOnce(testCase)
    root=setupPaths(); folder=tempname(fullfile(root,'results')); mkdir(folder);
    testCase.TestData.root=folder;
    warningState=warning('off','initSettings:FileMissing');
    testCase.TestData.restoreWarnings=onCleanup(@() warning(warningState));
end

function teardownOnce(testCase)
    testCase.TestData.restoreWarnings=[];
end

function testPreviouslyDroppedSettingsAndLegacyFlags(testCase)
    raw=fixture(testCase);
    raw.pllMaxNcoHz=777; raw.pllSaturationHoldMs=123;
    raw.pllSaturationNcoRatio=.8; raw.pllSaturationRatio=.42;
    raw.reacqCnoConsecutive=4; raw.reacqCnoRecoverDbHz=35;
    raw.Th_static_tracking_dBm=-95;
    raw.FLL=struct('gainLong',.007); raw.KF=struct('qJerk',.123);
    raw.nmea=struct('enable',false,'bdtMinusUtc',9);
    raw.truePosition=struct('E',[],'N',NaN,'U',12);
    raw.extension=struct('marker',42);
    actual=compareEntrypoints(testCase,raw);
    verifyEqual(testCase,actual.pllMaxNcoHz,777);
    verifyEqual(testCase,actual.pllSaturationRatio,.42);
    verifyEqual(testCase,actual.reacqCnoConsecutive,4);
    verifyEqual(testCase,actual.FLL.gainLong,.007);
    verifyTrue(testCase,actual.FLL.enable); % a partial nested override keeps defaults
    verifyEqual(testCase,actual.KF.qJerk,.123);
    verifyEqual(testCase,actual.nmea.utcOffsetSeconds,9);
    verifyFalse(testCase,actual.nmea.enable);
    verifyFalse(testCase,actual.plotNavPost);
    verifyFalse(testCase,actual.plotBaiduMap);
    verifyTrue(testCase,isnan(actual.truePosition.E));
    verifyEqual(testCase,actual.extension.marker,42);
end

function testFormatsRatesAndExplicitFrontend(testCase)
    for fs=[25e6 30.69e6]
        for dtype={'int8','int16'}
            raw=fixture(testCase); raw.samplingFreq=fs; raw.dataType=dtype{1};
            raw.EnablePB=true;
            raw.PB_settings=struct('Th_static',10,'Th_static_tracking',20);
            raw.Frontend=struct('mode','tf_v1','TF',struct('stopbandWidthHz',800e3,'triangleSpanUs',3));
            actual=compareEntrypoints(testCase,raw);
            verifyEqual(testCase,actual.Frontend.TF.effectiveTaps,2*ceil(320*fs/25e6)+1);
            verifyEqual(testCase,actual.Frontend.TF.K,round(3e-6*fs/2));
            verifyEqual(testCase,actual.Frontend.TF.effectiveThresholdAmplitude,20);
            verifyFalse(testCase,actual.EnablePB);
        end
    end
end

function testDerivedFieldsUseFinalOverrides(testCase)
    raw=fixture(testCase); raw.samplingFreq=12e6; raw.codeFreqBasis=5e6;
    raw.usrp=struct('scaleK',-88,'gain',15);
    raw.Th_static_dBm=-92; raw.Th_static_tracking_dBm=-96;
    raw.pllNoiseBandwidth_pull=23; raw.pllNoiseBandwidth_stab=7;
    raw.dllNoiseBandwidth_stab=1.5; raw.REACQ_max=3; raw.parMaxWorkers=20;
    actual=compareEntrypoints(testCase,raw);
    verifyEqual(testCase,actual.PB_settings.Th_static,10^((-92+88-15+10*log10(12e6))/20),'RelTol',1e-14);
    verifyEqual(testCase,actual.PB_settings.Th_static_tracking,10^((-96+88-15+10*log10(12e6))/20),'RelTol',1e-14);
    verifyEqual(testCase,actual.fineCodeSearchHalfWinSamples,5);
    verifyEqual(testCase,actual.pllNoiseBandwidth_init,23);
    verifyEqual(testCase,actual.pllNoiseBandwidth,7);
    verifyEqual(testCase,actual.dllNoiseBandwidth,1.5);
    verifyEqual(testCase,actual.REACQ_eachTimeWaitMs,[0 100 200]);
    verifyEqual(testCase,actual.parMaxWorkers,6);
    args=namedargs2cell(raw); nv=initSettings(args{:}); st=initSettings(raw);
    verifyTrue(testCase,isequaln(nv,st));
end

function testExplicitDerivedValuesAndCanonicalAliasesWin(testCase)
    raw=fixture(testCase); raw.samplingFreq=30.69e6;
    raw.fineCodeSearchHalfWinSamples=11;
    raw.PB_settings=struct('Th_static',12,'Th_static_tracking',23);
    raw.Th_static_dBm=-20; raw.Th_static_tracking_dBm=-21;
    raw.pllNoiseBandwidth=9; raw.pllNoiseBandwidth_stab=8;
    raw.pllNoiseBandwidth_init=27; raw.nmea=struct('bdtMinusUtc',9,'utcOffsetSeconds',4);
    actual=compareEntrypoints(testCase,raw);
    verifyEqual(testCase,actual.fineCodeSearchHalfWinSamples,11);
    verifyEqual(testCase,actual.PB_settings.Th_static,12);
    verifyEqual(testCase,actual.PB_settings.Th_static_tracking,23);
    verifyEqual(testCase,actual.pllNoiseBandwidth,8);
    verifyEqual(testCase,actual.pllNoiseBandwidth_pull,27);
    verifyEqual(testCase,actual.nmea.utcOffsetSeconds,4);
end

function testDurationAndSkipGeometry(testCase)
    raw=fixture(testCase); raw.samplingFreq=1000; raw.dataType='int16';
    raw.fileName='six_seconds.dat'; raw.skipNumberOfBytes=4000; raw.msToProcess=9000;
    raw.skipAcquisition=true;
    fid=fopen(fullfile(raw.filePath,raw.fileName),'wb'); assert(fid>=0);
    fwrite(fid,zeros(1,12000,'int16'),'int16'); fclose(fid);
    actual=compareEntrypoints(testCase,raw);
    verifyEqual(testCase,actual.size_per_sample,4);
    verifyEqual(testCase,actual.msToProcess,4000); % 6 s - 1 s skip - 1 s reserve
    raw.fileName='missing.dat'; raw=rmfield(raw,'skipNumberOfBytes');
    actual=compareEntrypoints(testCase,raw);
    verifyEqual(testCase,actual.skipNumberOfBytes,3005*1000*4);
end

function testPrnTextAndLegacyEnablePb(testCase)
    raw=fixture(testCase); raw.acqSatelliteList='11:2:15'; raw.EnablePB=false;
    actual=compareEntrypoints(testCase,raw);
    verifyEqual(testCase,actual.acqSatelliteList,[11 13 15]);
    verifyEqual(testCase,actual.Frontend.mode,'off');
    raw.acqSatelliteList='11;13,15'; raw.EnablePB=true;
    actual=compareEntrypoints(testCase,raw);
    verifyEqual(testCase,actual.acqSatelliteList,[11 13 15]);
    verifyEqual(testCase,actual.Frontend.mode,'pb');
    raw.acqSatelliteList='not a PRN';
    verifyError(testCase,@() initSettings(raw),'initSettings:BadPrnList');
end

function testWrapperOverridesAndSnapshotReplay(testCase)
    raw=fixture(testCase); raw.doPlot=false; raw.doNmea=false;
    rd=fullfile(raw.resultRoot,'wrapper'); report=runFromSettings(raw,'outDir',rd, ...
        'tag','explicit_tag','doPlot',true,'doNmea',true,'doBaiduMap',false,'openBaiduBrowser',false);
    verifyEqual(testCase,report.tag,'explicit_tag');
    a=load(fullfile(rd,'ui_results.mat'),'settings');
    verifyTrue(testCase,a.settings.plotNavPost); verifyTrue(testCase,a.settings.nmea.enable);
    verifyFalse(testCase,a.settings.plotBaiduMap);
    replayDir=fullfile(raw.resultRoot,'replay');
    replay=runFromJsonConfig(fullfile(rd,'ui_config.json'),'outDir',replayDir,'openBaiduBrowser',false);
    b=load(fullfile(replayDir,'ui_results.mat'),'settings');
    verifyEqual(testCase,replay.tag,'explicit_tag');
    verifyTrue(testCase,isequaln(withoutOutput(a.settings),withoutOutput(b.settings)));
end

function testRejectedGeometryIsTransportIndependent(testCase)
    raw=fixture(testCase); raw.fileName='tiny.dat'; raw.samplingFreq=1000;
    fid=fopen(fullfile(raw.filePath,raw.fileName),'wb'); fwrite(fid,zeros(1,100,'int8'),'int8'); fclose(fid);
    path=fullfile(raw.resultRoot,'tiny.json'); writeJson(path,raw);
    verifyError(testCase,@() initSettings(raw),'initSettings:FileTooShort');
    verifyError(testCase,@() runFromJsonConfig(path,'outDir',fullfile(raw.resultRoot,'json')), 'initSettings:FileTooShort');
    verifyError(testCase,@() runFromSettings(raw,'outDir',fullfile(raw.resultRoot,'struct')), 'initSettings:FileTooShort');
end

function raw=fixture(testCase)
    folder=tempname(testCase.TestData.root); mkdir(folder);
    raw=struct('filePath',folder,'fileName','missing.dat','samplingFreq',25e6, ...
        'dataType','int16','fileType',2,'msToProcess',10,'skipNumberOfBytes',0, ...
        'acqSatelliteList',[11 19],'plotNavPost',false,'plotBaiduMap',false, ...
        'tag','preserve_this_tag','resultRoot',folder,'tempdataSvPth',folder);
end

function actual=compareEntrypoints(testCase,raw)
% Missing IF (or explicit skipAcquisition) stops before expensive processing;
% ui_results.mat still contains the real settings delivered to the pipeline.
    cfg=fullfile(raw.resultRoot,'config.json'); writeJson(cfg,raw);
    sources={cfg,raw,initSettings(raw)}; effective=cell(1,3);
    for k=1:3
        rd=tempname(raw.resultRoot);
        if k==3
            report=runFromSettings(sources{k},'outDir',rd,'openBaiduBrowser',false,'closeFigures',true);
        else
            report=runFromJsonConfig(sources{k},'outDir',rd,'openBaiduBrowser',false,'closeFigures',true);
        end
        verifyFalse(testCase,report.ok); verifyEqual(testCase,report.tag,raw.tag);
        verifyTrue(testCase,ismember(report.errorIdentifier,{'openIfFile:CannotOpen','runFromJsonConfig:SkipAcq'}));
        loaded=load(fullfile(rd,'ui_results.mat'),'settings'); effective{k}=withoutOutput(loaded.settings);
    end
    verifyTrue(testCase,isequaln(effective{1},effective{2}),'JSON and raw struct differ.');
    verifyTrue(testCase,isequaln(effective{1},effective{3}),'JSON and initSettings/wrapper differ.');
    actual=effective{1};
end

function settings=withoutOutput(settings)
    settings=rmfield(settings,{'resultRoot','tempdataSvPth','outDir'});
end

function writeJson(path,value)
    fid=fopen(path,'w','n','UTF-8'); assert(fid>=0); cleaner=onCleanup(@() fclose(fid));
    fprintf(fid,'%s',jsonencode(value));
end
