function report=exp34_jt65_sync_controls(sourceDir,opts)
%EXP34_JT65_SYNC_CONTROLS 同步负样本与时间/频偏测试，不连接硬件。
arguments
    sourceDir (1,1) string
    opts.NoiseTrials (1,1) double {mustBeInteger,mustBePositive}=100
end
sourceDir=char(sourceDir);
C=load(fullfile(sourceDir,'rx_capture.mat')); S=load(fullfile(sourceDir,'tx_reference.mat'));
original=double(C.rx(:)); fsRx=C.fsRx; stats=C.stats;
outDir=fullfile(sourceDir,['sync_controls_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]);
mkdir(outDir);
copyfile(which('exp34_jt65_live'),fullfile(outDir,'exp34_jt65_live.m'));
workDir=tempname; mkdir(workDir); cleanup=onCleanup(@() rmdir(workDir,'s'));
save(fullfile(workDir,'tx_reference.mat'),'-struct','S');
rx=original; save(fullfile(workDir,'rx_capture.mat'),'rx','fsRx','stats');
evalc('base=exp34_jt65_live(ReplayDirectory=string(workDir),ShowPlots=false,SyncMode="legacy");');
signalPower=10^(base.snr.signalDbFS/10); baseNoise=10^(base.snr.noiseDbFS/10);
snrDb=-12; variance=(signalPower/10^(snrDb/10)-baseNoise)*fsRx/400;
t=(0:numel(original)-1).'/fsRx;
records=struct('kind',{},'seed',{},'offsetHz',{},'delaySeconds',{}, ...
    'syncAccepted',{},'decoderAccepted',{},'passed',{},'timeErrorSeconds',{},'frequencyErrorHz',{});
logF=fopen(fullfile(outDir,'summary.txt'),'w'); logCleanup=onCleanup(@() fclose(logF));
offsets=[-15 -7.5 0 7.5 15];
nTone=20; nShift=2*numel(offsets); nAll=opts.NoiseTrials+nTone+nShift;
for k=1:nAll
    seed=781013+k; rng(seed,'twister');
    noise=sqrt(variance/2)*(randn(size(original))+1i*randn(size(original)));
    offset=0; delay=0;
    if k<=opts.NoiseTrials
        kind='noise'; rx=noise;
    elseif k<=opts.NoiseTrials+nTone
        kind='continuous_tone';
        % 连续单音没有公开的同步时隙开关图样；强度高于待测弱信号。
        offset=offsets(mod(k-opts.NoiseTrials-1,numel(offsets))+1);
        rx=noise+sqrt(10*signalPower)*exp(2i*pi*(S.fSync+offset)*t);
    else
        kind='shifted_signal';
        j=k-opts.NoiseTrials-nTone;
        offset=offsets(mod(j-1,numel(offsets))+1);
        if j<=numel(offsets), delay=-0.61; else, delay=0.44; end
        shift=round(delay*fsRx); delay=shift/fsRx;
        shifted=complex(zeros(size(original)));
        if shift>=0
            shifted(1+shift:end)=original(1:end-shift);
        else
            shifted(1:end+shift)=original(1-shift:end);
        end
        rx=shifted.*exp(2i*pi*offset*t)+noise;
    end
    save(fullfile(workDir,'rx_capture.mat'),'rx','fsRx','stats');
    accepted=false; decoded=false; passed=false; timeError=NaN; freqError=NaN; R=struct;
    try
        evalc('R=exp34_jt65_live(ReplayDirectory=string(workDir),ShowPlots=false);');
        accepted=true; decoded=R.decoderAccepted; passed=R.passed;
        if strcmp(kind,'shifted_signal')
            timeError=R.frameStartSeconds-base.frameStartSeconds-delay;
            freqError=R.frequencyOffset-base.frequencyOffset-offset;
        else
            % 若控制样本意外通过，保存输入供排查；不因参考消息不匹配而隐藏误检。
            save(fullfile(outDir,sprintf('false_alarm_%d.mat',k)),'rx','fsRx','stats','R');
        end
    catch ME
        if ~strcmp(ME.identifier,'JT65:SyncNotFound'), rethrow(ME); end
    end
    records(k)=struct('kind',kind,'seed',seed,'offsetHz',offset,'delaySeconds',delay, ...
        'syncAccepted',accepted,'decoderAccepted',decoded,'passed',passed, ...
        'timeErrorSeconds',timeError,'frequencyErrorHz',freqError);
    analysisDirs=dir(fullfile(workDir,'analysis_*'));
    for d=1:numel(analysisDirs)
        if analysisDirs(d).isdir, rmdir(fullfile(workDir,analysisDirs(d).name),'s'); end
    end
    if mod(k,20)==0 || k>opts.NoiseTrials+nTone
        msg=sprintf('%d/%d | %s | CFO %+.1f Hz | delay %+.2f s | sync %d decode %d correct %d\n', ...
            k,nAll,kind,offset,delay,accepted,decoded,passed);
        fprintf('%s',msg); fprintf(logF,'%s',msg);
    end
end
report=struct('sourceDirectory',sourceDir,'outputDirectory',outDir, ...
    'records',records,'signalSnrDb400Hz',snrDb,'noiseVariance',variance);
save(fullfile(outDir,'control_report.mat'),'report');
fprintf('CONTROL_DIRECTORY=%s\n',outDir);
end
