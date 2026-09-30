function tests=test_tf_frontend
% Production frontend against independent direct-convolution/file references.
    tests=functiontests(localfunctions);
end

function setupOnce(testCase)
    root=setupPaths();
    base=fullfile(root,'results','upgrade_v020','unit_tests');
    if ~isfolder(base), mkdir(base); end
    testCase.TestData.root=base;
end

function testFormatRateBandwidthCombinations(testCase)
    for dtype={'int8','int16'}
        for fs=[25e6 30.69e6]
            for bw=[400e3 600e3 800e3]
                [s,x]=fixture(testCase,dtype{1},fs,12000);
                s.Frontend=struct('mode','tf_v1','TF',struct('stopbandWidthHz',bw));
                source=IFSource(s); cleaner=onCleanup(@() delete(source));
                t=source.Info.TF; H=t.H; D=t.D; K=t.K;
                expectedD=ceil(320*fs/25e6);
                verifyEqual(testCase,D,expectedD);
                low=fir1(2*D,(bw/2+75000)/(fs/2),kaiser(2*D+1,5.65326));
                h=-low.*exp(1i*2*pi*(-450e3)/fs*(-D:D)); h(D+1)=h(D+1)+1;
                g=max(K-abs(-K:K),0)/K^2;
                m=abs(x)>=s.PB_settings.Th_static_tracking;
                w=conv(movmax(double(m),[D+t.P+K D+t.P+K]),g,'same');
                reference=(1-w).*x+w.*conv(x,h,'same');
                [whole,meta]=source.readRange(0,numel(x));
                valid=H+1:numel(x)-H;
                verifyLessThan(testCase,max(abs(whole(valid)-reference(valid)))/max(abs(x)),1e-12);
                verifyEqual(testCase,find(meta.valid),valid);
                verifyEqual(testCase,whole(~meta.valid),x(~meta.valid));
                stream=RandStream('mt19937ar','Seed',20261001);
                lengths=[1 7 641 997 223 randi(stream,[1 1800],1,24)];
                start=H; assembled=[]; counter=0;
                while start<numel(x)-H
                    counter=counter+1; count=min(lengths(mod(counter-1,numel(lengths))+1),numel(x)-H-start);
                    [piece,m0]=source.readRange(start,count);
                    verifyEqual(testCase,m0.logicalStartAbs,start);
                    verifyEqual(testCase,m0.validCount,count);
                    assembled=[assembled piece]; %#ok<AGROW>
                    start=start+count;
                end
                verifyLessThan(testCase,max(abs(assembled-reference(valid)))/max(abs(x)),1e-12);
                % Cursor and raw byte seeking must be independent of the halo.
                source.seekAbs(3219); [~,m1]=source.read(257);
                verifyEqual(testCase,m1.logicalStartAbs,3219);
                verifyEqual(testCase,source.tellLogical(),3476);
                verifyEqual(testCase,source.readRawRange(3219,257),x(3220:3476));
                back=source.readRange(2500,600); source.readRange(7000,123);
                verifyEqual(testCase,source.readRange(2500,600),back);
                verifyEqual(testCase,source.tellLogical(),3476);
                [tail,m2]=source.readRange(numel(x)-9,50);
                verifyEqual(testCase,tail,x(end-8:end)); verifyEqual(testCase,m2.validCount,0);
                verifyEmpty(testCase,source.readRange(numel(x),20));
                % Negative control uses independently misaligned reference.
                nf=conv(x,h,'same'); wrong=(1-w(valid)).*x(valid)+w(valid).*nf(valid+1);
                verifyGreaterThan(testCase,max(abs(wrong-reference(valid)))/max(abs(x)),1e-4);
                % Negative control: independently process a short block with
                % zero extension instead of its real neighboring samples.
                cut=1800:2050; rawCut=x(cut);
                maskCut=abs(rawCut)>=s.PB_settings.Th_static_tracking;
                weightCut=conv(movmax(double(maskCut),[D+t.P+K D+t.P+K]),g,'same');
                noHalo=(1-weightCut).*rawCut+weightCut.*conv(rawCut,h,'same');
                verifyGreaterThan(testCase,max(abs(noHalo-reference(cut)))/max(abs(x)),1e-4);
                clear cleaner
            end
        end
    end
end

function testQuietIdentityAndThresholdTie(testCase)
    [s,~]=fixture(testCase,'int16',25e6,6000); s.Frontend=struct('mode','tf_v1');
    s.PB_settings.Th_static_tracking=10;
    tf=TFBlankerV1(s); raw=complex(ones(1,6000),ones(1,6000));
    [z,m]=tf.applyRange(raw,0,1000,1000);
    verifyEqual(testCase,z,raw(1001:2000)); verifyEqual(testCase,m.meanWeight,0);
    raw(3000)=10;
    [~,m]=tf.applyRange(raw,0,2999,1);
    verifyEqual(testCase,m.detectorDuty,1); verifyEqual(testCase,m.meanWeight,1);
    raw(2500)=NaN;
    verifyError(testCase,@() tf.applyRange(raw,0,1000,1000),'Frontend:InvalidInput');
end

function testImpulseAndSingleSidedFrequency(testCase)
    [s,~]=fixture(testCase,'int16',30.69e6,6000); s.Frontend=struct('mode','tf_v1');
    s.PB_settings.Th_static_tracking=.5;
    tf=TFBlankerV1(s); raw=zeros(1,6000); raw(3000)=1;
    [z,~]=tf.applyRange(raw,0,1000,4000); [~,peak]=max(abs(z));
    verifyEqual(testCase,peak+1000,3000);
    r=freqz(tf.Notch,1,2*pi*[-450e3 450e3]/s.samplingFreq);
    verifyLessThan(testCase,abs(r(1)),1e-3); verifyGreaterThan(testCase,abs(r(2)),.99);
end

function testExplicitOverrideAndValidation(testCase)
    [s,~]=fixture(testCase,'int8',30.69e6,6000);
    s.Frontend=struct('mode','tf_v1','TF',struct('firTaps',641));
    a=resolveFrontendSettings(s); verifyEqual(testCase,a.Frontend.TF.H,749);
    verifyEqual(testCase,resolveFrontendSettings(a),a);
    s.Frontend.TF.firTaps=640;
    verifyError(testCase,@() resolveFrontendSettings(s),'Frontend:InvalidTaps');
    s.Frontend.TF.firTaps=[]; s.Frontend.TF.centerHz=s.samplingFreq;
    verifyError(testCase,@() resolveFrontendSettings(s),'Frontend:InvalidBand');
    s.Frontend=struct('mode','tf_v2');
    verifyError(testCase,@() resolveFrontendSettings(s),'Frontend:NotImplemented');
    s.Frontend=struct('mode','tf_v1'); s.fileType=1;
    verifyError(testCase,@() resolveFrontendSettings(s),'Frontend:UnsupportedFormat');
end

function testLegacyOffAndPbNumericCompatibility(testCase)
    [s,x]=fixture(testCase,'int16',25e6,6000);
    s.EnablePB=false; off=IFSource(s); c1=onCleanup(@() delete(off));
    verifyEqual(testCase,off.read(2000),x(1:2000)); verifyEqual(testCase,off.Halo,0);
    s.EnablePB=true; pbSource=IFSource(s,'tracking'); c2=onCleanup(@() delete(pbSource));
    pbSettings=s; pbSettings.PB_settings.Th_static=pbSettings.PB_settings.Th_static_tracking;
    pb=pulseBlanker(pbSettings);
    for start=[0 500 2100]
        [y,m]=pbSource.readRange(start,500);
        expected=pb.mitigate(x(start+(1:500)));
        verifyEqual(testCase,y,expected); verifyEqual(testCase,m.eta,pb.PDC);
    end
    s.Frontend=struct('mode','off'); explicitOff=IFSource(s); c3=onCleanup(@() delete(explicitOff));
    verifyEqual(testCase,explicitOff.read(1000),x(1:1000));
    s.Frontend=struct('mode','tf_v1'); tf=IFSource(s); c4=onCleanup(@() delete(tf));
    verifyClass(testCase,tf.Mitigator,'TFBlankerV1'); verifyFalse(testCase,tf.Settings.EnablePB);
end

function testInvalidOffsetsAndIncompleteIq(testCase)
    [s,~]=fixture(testCase,'int16',25e6,6000); s.Frontend=struct('mode','tf_v1');
    s.skipNumberOfBytes=2;
    verifyError(testCase,@() IFSource(s),'IFSource:UnalignedOffset');
    s.skipNumberOfBytes=0;
    fid=fopen(fullfile(s.filePath,s.fileName),'ab'); fwrite(fid,int16(1),'int16'); fclose(fid);
    verifyError(testCase,@() IFSource(s),'IFSource:IncompleteIQ');
end

function testInitOverridesPrecedeDurationCap(testCase)
    [s,~]=fixture(testCase,'int8',1000,6000);
    actual=initSettings('filePath',s.filePath,'fileName',s.fileName, ...
        'samplingFreq',1000,'dataType','int8','fileType',2, ...
        'skipNumberOfBytes',2000,'msToProcess',4000, ...
        'resultRoot',s.filePath,'tempdataSvPth',s.filePath);
    verifyEqual(testCase,actual.msToProcess,4000);
    verifyEqual(testCase,actual.size_per_sample,2);
    verifyEqual(testCase,actual.skipNumberOfBytes,2000);
    verifyEqual(testCase,frontendSampleBytes('short',2),4);
end

function testAcquisitionOriginPropagation(testCase)
    s=struct('numberOfChannels',1,'acqSatelliteList',11,'codeFreqBasis',10.23e6);
    a=struct('carrFreq',100,'codePhase',321,'codePhaseAbs',125321, ...
        'peakMetric',5,'weilPhase',7,'polarityRef',1,'acqInputStartAbs',12345);
    ch=preRun2(a,s);
    verifyEqual(testCase,ch.trackStartAbs,12665);
    verifyEqual(testCase,ch.codePhaseAbs,125321);
    verifyEqual(testCase,ch.acqInputStartAbs,12345);
end

function testMetadataChunkRoundTrip(testCase)
    [s,~]=fixture(testCase,'int16',25e6,6000); s.Frontend=struct('mode','tf_v1');
    s.msToProcess=5; s.CNoInterval=2; s.tempdataSvPth=s.filePath;
    source=IFSource(s); cleaner=onCleanup(@() delete(source));
    tr=TrackResults2(s,5); tr.PRN=11; tr.frontendInfo=source.Info;
    for k=1:5
        [~,meta]=source.readRange(1000+(k-1)*100,100); tr.writeFrontend(k,meta);
    end
    verifyTrue(testCase,tr.partsave(s,3));
    stored=load(fullfile(s.filePath,'Trk_Prn_11_001.mat'),'chunk');
    verifyEqual(testCase,numel(stored.chunk.frontendValidCount),3);
    verifyEqual(testCase,stored.chunk.frontendInfo,source.Info);
    restored=TrackResults2.fromStruct(stored.chunk);
    destination=TrackResults2(s,8); destination.copyFROM(restored,4);
    verifyEqual(testCase,destination.frontendValidCount(4:6),[100 100 100]);
    verifyEqual(testCase,destination.frontendInfo,source.Info);
    verifyEqual(testCase,destination.frontendMeanWeight(4:6),restored.frontendMeanWeight);
end

function testJsonFrontendSelectionIsPreserved(testCase)
    [s,~]=fixture(testCase,'int16',25e6,6000);
    cfg=struct('filePath',s.filePath,'fileName','deliberately_missing.dat', ...
        'samplingFreq',25e6,'dataType','int16','fileType',2,'skipNumberOfBytes',0, ...
        'msToProcess',10,'numberOfChannels',1,'acqSatelliteList',11,'EnablePB',true, ...
        'PB_settings',s.PB_settings,'Frontend',struct('mode','tf_v1', ...
        'TF',struct('stopbandWidthHz',600e3)), 'doNavigation',false,'doPlot',false, ...
        'doNmea',false,'doBaiduMap',false);
    file=fullfile(s.filePath,'config.json'); fid=fopen(file,'w'); fprintf(fid,'%s',jsonencode(cfg)); fclose(fid);
    report=runFromJsonConfig(file,'outDir',fullfile(s.filePath,'run'),'openBaiduBrowser',false);
    verifyFalse(testCase,report.ok); % Deliberate missing-file error after config resolution.
    verifyEqual(testCase,report.frontend.mode,'tf_v1');
    verifyEqual(testCase,report.frontend.TF.stopbandWidthHz,600000);
    verifyEqual(testCase,report.frontend.TF.effectiveTaps,641);
end

function [s,x]=fixture(testCase,dtype,fs,N)
    folder=tempname(testCase.TestData.root); mkdir(folder);
    s=struct('filePath',folder,'fileName','iq.bin','fileType',2,'dataType',dtype, ...
        'samplingFreq',fs,'skipNumberOfBytes',0,'EnablePB',true, ...
        'PB_settings',struct('UseStatic',true,'Th_static',20,'Th_static_tracking',50, ...
        'falseAlert',1e-4,'Th_TTL',5,'debugplot',false));
    n=0:N-1; x=complex(round(5*cos(.13*n)),round(5*sin(.19*n)));
    x([1100 2000 2001 4000 5000])=100-70i;
    fid=fopen(fullfile(folder,s.fileName),'wb'); fwrite(fid,cast([real(x);imag(x)],dtype),dtype); fclose(fid);
end
