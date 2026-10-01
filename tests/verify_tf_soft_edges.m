function summary=verify_tf_soft_edges(outputRoot,bandwidthHz)
%VERIFY_TF_SOFT_EDGES Independent weight/alignment/file checks for edge sweep.
% triangleSpanUs is each outer transition's 2K/fs span, not K/fs.
    if nargin<2, bandwidthHz=600e3; end
    validateattributes(bandwidthHz,{'numeric'},{'scalar','positive','finite'});
    setupPaths(); assert(~isfolder(outputRoot)); mkdir(outputRoot);
    rows={}; curves={}; spans=[3 6 9 12];
    for fs=[25e6 30.69e6]
        coefficientHash='';
        for span=spans
            for dtype={'int8','int16'}
                N=16000; n=0:N-1; threshold=40;
                clean=2*exp(1i*(2*pi*1.7e6*n/fs+.3));
                envelope=zeros(1,N);
                for center=[2500 2500+round(12e-6*fs) 8000 12300]
                    envelope=envelope+90*exp(-.5*((n-center)/(1.5e-6*fs)).^2);
                end
                interference=envelope.*exp(1i*2*pi*(-450e3)*n/fs);
                iq=cast([real(clean+interference);imag(clean+interference)],dtype{1});
                x=double(iq(1,:))+1i*double(iq(2,:));
                file=sprintf('fixture_%g_%g_%s.dat',fs,span,dtype{1});
                fid=fopen(fullfile(outputRoot,file),'wb'); assert(fid>=0);
                fwrite(fid,iq,dtype{1}); fclose(fid);
                cfg=struct('samplingFreq',fs,'dataType',dtype{1},'fileType',2, ...
                    'filePath',outputRoot,'fileName',file,'skipNumberOfBytes',0, ...
                    'Frontend',struct('mode','tf_v1','TF',struct('stopbandWidthHz',bandwidthHz, ...
                    'triangleSpanUs',span,'thresholdAmplitude',threshold)));
                source=IFSource(cfg); cleaner=onCleanup(@() delete(source));
                tf=source.Mitigator; t=tf.Config;
                if isempty(coefficientHash), coefficientHash=tf.Info.coefficientHash; end
                assert(strcmp(coefficientHash,tf.Info.coefficientHash));
                g=max(t.K-abs(-t.K:t.K),0)/t.K^2;
                m=abs(x)>=threshold;
                w=conv(movmax(double(m),[t.A t.A]),g,'same');
                platform=movmax(double(m),[t.D+t.P t.D+t.P])>0;
                assert(abs(sum(g)-1)<1e-13 && min(w)>=-1e-12 && max(w)<=1+1e-12);
                assert(min(w(platform))>1-1e-12);
                assert(t.K==round(span*1e-6*fs/2) && t.A==t.D+t.P+t.K);
                assert(t.H==t.D+t.P+2*t.K);
                nf=conv(x,tf.Notch,'same'); reference=(1-w).*x+w.*nf;
                [whole,meta]=source.readRange(0,N); valid=t.H+1:N-t.H;
                assert(isequal(find(meta.valid),valid));
                assert(isequal(whole(~meta.valid),x(~meta.valid)));
                error=max(abs(whole(valid)-reference(valid)))/max(abs(x));
                assert(error<1e-12);
                start=t.H; chunkError=0; sizes=[1 7 251 641 997 53]; counter=0;
                while start<N-t.H
                    counter=counter+1; count=min(sizes(mod(counter-1,numel(sizes))+1),N-t.H-start);
                    [piece,pm]=source.readRange(start,count);
                    chunkError=max(chunkError,max(abs(piece-reference(start+(1:count))))/max(abs(x)));
                    assert(pm.logicalStartAbs==start && pm.validCount==count);
                    start=start+count;
                end
                assert(chunkError<1e-12);
                source.seekAbs(5000); source.read(127); assert(source.tellLogical()==5127);
                first=source.readRange(2500,501); source.readRange(9000,173);
                assert(isequal(first,source.readRange(2500,501)) && source.tellLogical()==5127);
                [tail,tm]=source.readRange(N-7,30);
                assert(isequal(tail,x(end-6:end)) && tm.validCount==0);
                quiet=complex(ones(1,N),ones(1,N));
                assert(isequal(tf.applyRange(quiet,0,t.H,N-2*t.H),quiet(valid)));
                wrong=(1-w(valid)).*x(valid)+w(valid).*nf(valid+1);
                wrongError=max(abs(wrong-reference(valid)))/max(abs(x));
                assert(wrongError>1e-4,'One-sample misalignment negative control failed.');
                cut=2450:2660; xc=x(cut);
                wc=conv(movmax(double(abs(xc)>=threshold),[t.A t.A]),g,'same');
                noHalo=(1-wc).*xc+wc.*conv(xc,tf.Notch,'same');
                noHaloError=max(abs(noHalo-reference(cut)))/max(abs(x));
                assert(noHaloError>1e-4,'Missing-context negative control failed.');
                rows{end+1}=struct('samplingFreq',fs,'dataType',dtype{1}, ...
                    'requestedOuterSpanUs',span,'actualOuterSpanUs',t.actualTriangleSpanUs, ...
                    'D',t.D,'K',t.K,'P',t.P,'A',t.A,'H',t.H, ...
                    'coefficientHash',tf.Info.coefficientHash,'triangleSum',sum(g), ...
                    'platformMinimum',min(w(platform)),'referenceRelativeError',error, ...
                    'chunkRelativeError',chunkError,'wrongShiftRelativeError',wrongError, ...
                    'missingContextRelativeError',noHaloError,'passed',true); %#ok<AGROW>
                if strcmp(dtype{1},'int16')
                    axis=-2*t.H:2*t.H; mask=double(axis==0);
                    weight=conv(movmax(mask,[t.A t.A]),g,'same');
                    curves{end+1}=struct('fs',fs,'spanUs',span,'timeUs',axis/fs*1e6, ...
                        'weight',weight,'platformHalfUs',(t.D+t.P)/fs*1e6); %#ok<AGROW>
                end
                clear cleaner
            end
        end
    end
    summary=struct('bandwidthHz',bandwidthHz,'outerSpansUs',spans,'allPassed',true, ...
        'cases',{rows},'scriptHash',frontendHash(fileread([mfilename('fullpath') '.m'])));
    fid=fopen(fullfile(outputRoot,'soft_edge_verification.json'),'w','n','UTF-8'); assert(fid>=0);
    cleaner=onCleanup(@() fclose(fid)); fprintf(fid,'%s\n',jsonencode(summary,'PrettyPrint',true)); clear cleaner
    save(fullfile(outputRoot,'soft_edge_curves.mat'),'curves','summary');
    f=figure('Visible','off','Position',[100 100 1050 780]); cleaner=onCleanup(@() close(f));
    tiledlayout(2,1);
    for fs=[25e6 30.69e6]
        nexttile; hold on;
        for j=1:numel(curves)
            c=curves{j}; if c.fs~=fs, continue; end
            platformHalfUs=c.platformHalfUs;
            plot(c.timeUs,c.weight,'DisplayName',sprintf('%g us outer transition',c.spanUs));
        end
        xline(-platformHalfUs,':','HandleVisibility','off');
        xline(platformHalfUs,':','HandleVisibility','off');
        title(sprintf('Single detected sample; fs=%.2f MHz; unchanged full-weight platform',fs/1e6));
        xlabel('Time relative to detected sample (us)'); ylabel('Notch weight');
        xlim([-32 32]); ylim([-.03 1.05]); grid on; legend('Location','best');
    end
    exportgraphics(f,fullfile(outputRoot,'soft_edge_weights.png'),'Resolution',150);
end
