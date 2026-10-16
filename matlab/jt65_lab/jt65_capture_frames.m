function batch=jt65_capture_frames(userMsg,opts)
% 连续多帧 TX/RX：整组采集共用一对 SDRu 对象，分析前才释放设备。
% 每帧以小块写入磁盘，避免多帧 IQ 占满内存。FrameCount=0 表示直到请求停止。
arguments
    userMsg (1,1) string = "hello"
    opts.FrameCount (1,1) double = NaN
    opts.SpeedMode (1,1) string {mustBeMember(opts.SpeedMode,["fast","slow"])} = "fast"
    opts.Serial (1,1) string = ""
    opts.CenterFrequency (1,1) double {mustBePositive} = 435e6
    opts.TxGain (1,1) double {mustBeNonnegative} = 30
    opts.RxGain (1,1) double {mustBeNonnegative} = 40
    opts.StopFcn = []
    opts.ProgressFcn = []
end
T=jt65_timing(opts.SpeedMode);
if isnan(opts.FrameCount), opts.FrameCount=T.minuteFrames; end
validateattributes(opts.FrameCount,{'double'},{'finite','integer','nonnegative','scalar'});
S=jt65_payload_frame(userMsg,1,SpeedMode=opts.SpeedMode);
nReferences=S.sequenceLength;
if opts.FrameCount>0, nReferences=min(nReferences,opts.FrameCount); end
references=cell(nReferences,1); references{1}=S;
for k=2:nReferences, references{k}=jt65_payload_frame(userMsg,k,SpeedMode=opts.SpeedMode); end
root=fileparts(fileparts(fileparts(mfilename('fullpath'))));
outDir=fullfile(root,'data',['jt65_loop_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]);
mkdir(outDir); save(fullfile(outDir,'tx_reference.mat'),'-struct','S');
ri=findsdru; good=strcmp({ri.Platform},'B210') & strncmp({ri.Status},'Success',7);
radios=ri(good);
if strlength(opts.Serial)>0, radios=radios(strcmp({radios.SerialNum},char(opts.Serial))); end
assert(isscalar(radios),'需要一台可用 B210；多台设备时请指定序列号。');
serial=radios.SerialNum; fsRadio=T.radioRate; chunk=T.chunk;
nLead=T.nLead; nTotal=T.nTotal;
% 相同字符共享硬件波形；全部插值在开启设备之前完成。
messages=cellfun(@(s)s.userMsg,references,'UniformOutput',false);
[~,uniqueReferences,patternIndex]=unique(messages,'stable');
patterns=complex(zeros(nTotal,numel(uniqueReferences),'single'));
rateGcd=gcd(fsRadio,S.fs); pRate=fsRadio/rateGcd; qRate=S.fs/rateGcd;
for k=1:numel(uniqueReferences)
    w=single(references{uniqueReferences(k)}.wave);
    if pRate~=qRate, w=resample(w,pRate,qRate); end
    assert(numel(w)==T.radioWaveSamples,'硬件波形长度与时长配置不一致。');
    patterns(nLead+(1:numel(w)),k)=w*(single(0.3)/max(abs(w)));
end
clear w
zero=complex(zeros(chunk,1,'single'));
% 有限循环的目录提前创建，避免帧边界的磁盘操作耗尽发送缓冲。
for k=1:opts.FrameCount
    mkdir(fullfile(outDir,sprintf('frame_%05d',k)));
end
tx=comm.SDRuTransmitter('Platform','B210','SerialNum',serial,'MasterClockRate',30.72e6, ...
    'InterpolationFactor',150,'CenterFrequency',opts.CenterFrequency,'Gain',opts.TxGain, ...
    'ChannelMapping',1,'UnderrunOutputPort',true);
txCleanup=onCleanup(@()release(tx));
rxObj=comm.SDRuReceiver('Platform','B210','SerialNum',serial,'MasterClockRate',30.72e6, ...
    'DecimationFactor',150,'CenterFrequency',opts.CenterFrequency,'Gain',opts.RxGain, ...
    'ChannelMapping',1,'SamplesPerFrame',chunk,'OutputDataType','single');
rxCleanup=onCleanup(@()release(rxObj));
ready=0; started=tic;
while ready<10
    assert(toc(started)<30,'接收机 30 秒内未就绪。');
    tx(zero); [~,n,o]=rxObj();
    if n==chunk && o==0, ready=ready+1; else, ready=0; end
end
captures=struct('directory',{},'rawPath',{},'stats',{}); stopRequested=false; frameIndex=0;
fprintf('连续采集已启动：单次打开 B210 %s；每帧 %.2f 秒（含保护空白）。\n',serial,nTotal/fsRadio);
while opts.FrameCount==0 || frameIndex<opts.FrameCount
    frameIndex=frameIndex+1;
    referenceIndex=mod(frameIndex-1,numel(references))+1;
    folder=fullfile(outDir,sprintf('frame_%05d',frameIndex));
    if opts.FrameCount==0, mkdir(folder); end
    rawPath=fullfile(folder,'raw_iq.f32'); fid=fopen(rawPath,'wb');
    assert(fid>=0,'无法创建原始 IQ 文件。');
    fileCleanup=onCleanup(@()fclose(fid));
    count=0; under=0; payloadUnder=0; over=0; empty=0; powerSum=0; peak=0; clipped=0;
    nextProgress=fsRadio;
    for p=1:chunk:nTotal
        q=p+chunk-1;
        u=tx(patterns(p:q,patternIndex(referenceIndex))); [y,n,o]=rxObj(); n=double(n);
        under=under+double(u~=0); over=over+double(o~=0);
        if u~=0 && q>nLead, payloadUnder=payloadUnder+1; end
        if n>0
            y=y(1:n); written=fwrite(fid,[real(y),imag(y)].','single');
            assert(written==2*n,'写入 IQ 文件失败，已停止采集。');
            count=count+n; yd=double(y); powerSum=powerSum+sum(abs(yd).^2);
            peak=max(peak,max(abs(yd))); clipped=clipped+nnz(abs(real(y))>=0.99 | abs(imag(y))>=0.99);
        else
            empty=empty+1;
        end
        if q>=nextProgress || q==nTotal
            fprintf('第 %d 帧：%.1f / %.1f 秒；欠载 %d，溢出 %d\n',frameIndex,q/fsRadio,nTotal/fsRadio,under,over);
            if ~isempty(opts.ProgressFcn), opts.ProgressFcn(frameIndex,q/fsRadio,nTotal/fsRadio); end
            if ~isempty(opts.StopFcn), stopRequested=stopRequested || opts.StopFcn(); end
            nextProgress=nextProgress+fsRadio;
        end
    end
    clear fileCleanup
    savedOpts=rmfield(opts,{'StopFcn','ProgressFcn'});
    stats=struct('serial',serial,'options',savedOpts,'sampleRate',fsRadio,'rxSamples',count, ...
        'underruns',under,'payloadUnderruns',payloadUnder,'overruns',over,'emptyReads',empty, ...
        'rxRawRmsDbFS',10*log10(powerSum/max(count,1)),'rxRawPeakDbFS',20*log10(peak), ...
        'rxClippedSamples',clipped,'continuousBatch',true,'frameIndex',frameIndex,'referenceIndex',referenceIndex);
    captures(frameIndex)=struct('directory',folder,'rawPath',rawPath,'stats',stats);
    if stopRequested, break; end
end
% 先停止收发，再按参考波形采样率保存接收数据；原始 204.8 kS/s IQ 保留。
clear txCleanup
clear rxCleanup
clear patterns
save(fullfile(outDir,'capture_index.mat'),'captures','stopRequested');
for k=1:numel(captures)
    input=fopen(captures(k).rawPath,'rb');
    assert(input>=0,'无法重新读取原始 IQ。');
    closeInput=onCleanup(@()fclose(input));
    values=fread(input,[2 Inf],'single=>single'); clear closeInput
    raw=complex(values(1,:),values(2,:)).'; clear values
    if pRate~=qRate, raw=resample(raw,qRate,pRate); end
    rx=double(raw); clear raw
    fsRx=S.fs; captureMode='MATLAB B210 continuous multi-frame TX/RX'; stats=captures(k).stats;
    save(fullfile(captures(k).directory,'rx_capture.mat'),'rx','fsRx','captureMode','stats');
    S=references{captures(k).stats.referenceIndex};
    save(fullfile(captures(k).directory,'tx_reference.mat'),'-struct','S');
end
batch=struct('outputDirectory',outDir,'captures',captures,'stopRequested',stopRequested, ...
    'sourceMessage',char(userMsg),'frameCount',numel(captures),'payloadBitsSent',numel(captures)*S.payloadBitCount, ...
    'speedMode',char(opts.SpeedMode),'payloadSeconds',T.payloadSeconds,'frameSeconds',nTotal/fsRadio,'captureSeconds',numel(captures)*nTotal/fsRadio,'options',savedOpts);
save(fullfile(outDir,'batch.mat'),'batch');
fprintf('连续采集结束：%d 帧；设备已释放。\n',batch.frameCount);

end
