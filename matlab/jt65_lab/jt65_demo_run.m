function P=jt65_demo_run(cfg)
% 展示窗口的同步执行入口；图形仅在本函数完成后刷新。
root=fileparts(fileparts(fileparts(mfilename('fullpath'))));
outDir=fullfile(root,'data',['jt65_app_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]);
mkdir(outDir);
mode=string(cfg.Mode); sourceDir=''; originalSnr=NaN;
speedMode="fast"; if isfield(cfg,'SpeedMode'), speedMode=string(cfg.SpeedMode); end
if mode=="仿真演示"
    S=jt65_payload_frame(string(cfg.Message),1,SpeedMode=speedMode); fsRx=S.fs;
    nGuard=round(0.2*fsRx);
    rx=complex(zeros(2*nGuard+numel(S.wave),1));
    rx(nGuard+(1:numel(S.wave)))=0.3*S.wave;
    rx=rx.*exp(2i*pi*cfg.FrequencyOffset*(0:numel(rx)-1).'/fsRx);
    signalPower=0.3^2; baseNoisePower=0;
    stats=struct('payloadUnderruns',0,'overruns',0,'emptyReads',0);
elseif mode=="USRP 真机收发"
    if isfield(cfg,'CaptureDirectory') && ~isempty(cfg.CaptureDirectory)
        sourceDir=char(cfg.CaptureDirectory);
    else
    capture=jt65_cli_capture('Message',string(cfg.Message),'FrameCount',1,'SpeedMode',speedMode,'Serial',string(cfg.Serial), ...
        'CenterFrequency',cfg.CenterMHz*1e6,'TxGain',cfg.TxGain,'RxGain',cfg.RxGain);
    sourceDir=capture.captures(1).directory;
    end
else
    sourceDir=char(cfg.SourceDirectory);
end
if mode~="仿真演示"
    assert(isfile(fullfile(sourceDir,'rx_capture.mat')) && isfile(fullfile(sourceDir,'tx_reference.mat')), ...
        '请选择包含 rx_capture.mat 与 tx_reference.mat 的一次采集目录。');
    C=load(fullfile(sourceDir,'rx_capture.mat')); S=load(fullfile(sourceDir,'tx_reference.mat'));
    rx=double(C.rx(:)); fsRx=C.fsRx; stats=C.stats;
    if cfg.AddNoise
        evalc('baseline=exp34_jt65_live(ReplayDirectory=string(sourceDir),ShowPlots=false);');
        signalPower=10^(baseline.snr.signalDbFS/10);
        assert(isfinite(signalPower) && signalPower>0,'原始录波的信号功率无法可靠估计，不能设定加噪 SNR。');
        baseNoisePower=baseline.snr.noiseDensity*cfg.Bandwidth;
        originalSnr=10*log10(signalPower/baseNoisePower);
    end
end
if cfg.AddNoise
    addedPower=signalPower/10^(cfg.SnrDb/10)-baseNoisePower;
    assert(addedPower>0,'目标 SNR 高于原始录波的 %.1f dB，无法通过加噪达到。请调低目标或关闭加噪。',originalSnr);
    rng(cfg.Seed,'twister');
    variance=addedPower*fsRx/cfg.Bandwidth;
    rx=rx+sqrt(variance/2)*(randn(size(rx))+1i*randn(size(rx)));
end
processed=fullfile(outDir,'processed'); mkdir(processed);
save(fullfile(processed,'tx_reference.mat'),'-struct','S');
captureMode=char(mode);
save(fullfile(processed,'rx_capture.mat'),'rx','fsRx','stats','captureMode');
result=[]; failure='';
decoderMode="hard"; if isfield(cfg,'DecoderMode'), decoderMode=string(cfg.DecoderMode); end
detectionMode="noncoherent"; if isfield(cfg,'DetectionMode'), detectionMode=string(cfg.DetectionMode); end
try
    evalc('result=exp34_jt65_live(ReplayDirectory=string(processed),ShowPlots=false,DecoderMode=decoderMode,DetectionMode=detectionMode);');
catch ME
    if strcmp(ME.identifier,'JT65:SyncNotFound')
        failure=ME.message;
    else
        rethrow(ME);
    end
end
referenceSnrDb=NaN; referenceBandHz=[];
if ~isempty(result)
    referenceSnrDb=result.snr.signalDbFS-10*log10(result.snr.noiseDensity*cfg.Bandwidth);
    referenceBandHz=result.snr.noiseBandsHz;
end
P=struct('S',S,'rx',rx,'fs',fsRx,'result',result,'failure',failure, ...
    'config',cfg,'outputDirectory',outDir,'sourceDirectory',sourceDir, ...
    'referenceSnrDb',referenceSnrDb,'referenceBandHz',referenceBandHz, ...
    'referenceNoiseScale',cfg.Bandwidth/(460*S.fs/11025),'referenceIsEquivalent',true);
save(fullfile(outDir,'app_result.mat'),'P');
end
