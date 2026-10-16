function result = exp34_jt65_live(userMsg, opts)
%EXP34_JT65_LIVE 单台 B210 的实验三、四：纯 MATLAB 同时收发和自动解码。
%   result = exp34_jt65_live("hello")
%   result = exp34_jt65_live("test", Serial="3237C62")
%   result = exp34_jt65_live(ReplayDirectory="某次 data/jt65_live_时间 的完整路径")
%   ReplayDirectory 非空时仅重新分析已保存数据，不连接或发射硬件。
%   不指定 Serial 时自动选择唯一在线的 B210，支持更换设备。
%   接线：同一通道 ch1 的 TX/RX -> 发射天线，RX2 -> 接收天线。
%   流程：编码 -> 启动收发 -> 确认收到数据 -> 0.2 秒空白 -> 发一帧
%         -> 继续收尾 0.2 秒 -> 释放设备 -> 自动同步、解调、纠错。
%   命令窗口每秒显示进度。Ctrl+C 中断时自动释放收发对象。
%   一次运行的波形、采集、日志、结果放在 data/jt65_live_时间/。
%   默认 joint 同步：联合搜索时间与 ±20 Hz 频偏，选择最佳候选继续译码。
%   同步门限已取消：低得分不拦截；得分仅供观察，最终保留 RS 和误码检查。
%   SyncMode="legacy" 使用旧版幅度得分搜索，同样不设置同步得分门限。
%   DecoderMode="joint7" 对七比特格式比较全部 128 个码字；证据不足则未恢复。
%   旧 72 比特文字格式自动保留硬 RS。发送参考始终仅用于事后核对。
arguments
    userMsg (1,1) string = "1011010"
    opts.Serial (1,1) string = ""
    opts.CenterFrequency (1,1) double {mustBePositive} = 435e6
    opts.TxGain (1,1) double {mustBeNonnegative} = 30
    opts.RxGain (1,1) double {mustBeNonnegative} = 40
    opts.LeadSeconds (1,1) double {mustBePositive} = 0.2
    opts.TailSeconds (1,1) double {mustBePositive} = 0.2
    opts.ShowPlots (1,1) logical = true
    opts.CaptureOnly (1,1) logical = false
    opts.OutputDirectory (1,1) string = ""
    opts.ReplayDirectory (1,1) string = ""
    opts.DecoderMode (1,1) string {mustBeMember(opts.DecoderMode,["hard","erasure","joint7"])} = "hard"
    opts.DetectionMode (1,1) string {mustBeMember(opts.DetectionMode,["noncoherent","coherent"])} = "noncoherent"
    opts.SyncMode (1,1) string {mustBeMember(opts.SyncMode,["joint","legacy"])} = "joint"
end

if strlength(opts.ReplayDirectory)>0
    result = replayCapture(opts.ReplayDirectory,opts.ShowPlots,opts.SyncMode,opts.DecoderMode,opts.DetectionMode);
    return;
end
S = jt65_make_frame(userMsg);
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
outDir = fullfile(root,'data',['jt65_live_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]);
if strlength(opts.OutputDirectory)>0
    outDir=char(opts.OutputDirectory);
    assert(~isfile(fullfile(outDir,'rx_capture.mat')), '输出目录已经有录波，请选择新的目录。');
end
mkdir(outDir);
logPath = fullfile(outDir,'log.txt');
fid = fopen(logPath,'w');
assert(fid>=0,'无法创建日志：%s',logPath);
logCleanup = onCleanup(@() fclose(fid));
say(fid,'=== 实验三 + 实验四：单台 B210，纯 MATLAB ===\n');
say(fid,'发送消息："%s"；波形 %d 点，时长 %.2f 秒\n',userMsg,numel(S.wave),numel(S.wave)/S.fs);
say(fid,'输出目录：%s\n',outDir);
save(fullfile(outDir,'tx_reference.mat'),'-struct','S');

% 两个对象在同一个 MATLAB 会话使用相同的时钟、频率和采样率。
ri = findsdru;
good = strcmp({ri.Platform},'B210') & strncmp({ri.Status},'Success',7);
radios = ri(good);
if strlength(opts.Serial)>0
    radios = radios(strcmp({radios.SerialNum},char(opts.Serial)));
end
assert(~isempty(radios),'没有找到空闲的 B210；请检查 USB 并关闭其他占用该设备的收发程序。');
assert(isscalar(radios),'检测到多台 B210，请用 Serial="序列号" 指定一台。');
serialNum = radios(1).SerialNum;
say(fid,'已识别 B210 %s；中心频率 %.3f MHz，TX %.1f dB，RX %.1f dB\n', ...
    serialNum,opts.CenterFrequency/1e6,opts.TxGain,opts.RxGain);

radioRate = 204800;
masterClock = 30.72e6;
chunk = 4096; % 每块 20 ms；同一循环内 TX 和 RX 交替访问硬件缓冲。
zeroBlock = complex(zeros(chunk,1,'single'));
assert(S.fs==radioRate,'波形采样率必须与硬件一致。');
txWave = single(S.wave);
txWave = txWave * (single(0.3)/max(abs(txWave)));
txRmsDbFS = 20*log10(sqrt(mean(abs(double(txWave)).^2)));
say(fid,'发射数字波形：峰值 0.30，平均电平 %.2f dBFS；TX 增益为相对增益，未校准的射频功率不能报为 dBm。\n',txRmsDbFS);
nLead = ceil(opts.LeadSeconds*radioRate/chunk)*chunk;
nTail = ceil(opts.TailSeconds*radioRate/chunk)*chunk;
nTotal = ceil((nLead+numel(txWave)+nTail)/chunk)*chunk;
txStream = complex(zeros(nTotal,1,'single'));
txStream(nLead+(1:numel(txWave))) = txWave;
raw = complex(zeros(nTotal,1,'single'));

tx = comm.SDRuTransmitter('Platform','B210','SerialNum',serialNum, ...
    'MasterClockRate',masterClock,'InterpolationFactor',150, ...
    'CenterFrequency',opts.CenterFrequency,'Gain',opts.TxGain, ...
    'ChannelMapping',1,'UnderrunOutputPort',true);
txCleanup = onCleanup(@() release(tx));
rxObj = comm.SDRuReceiver('Platform','B210','SerialNum',serialNum, ...
    'MasterClockRate',masterClock,'DecimationFactor',150, ...
    'CenterFrequency',opts.CenterFrequency,'Gain',opts.RxGain, ...
    'ChannelMapping',1,'SamplesPerFrame',chunk,'OutputDataType','single');
rxCleanup = onCleanup(@() release(rxObj));

say(fid,'正在启动收发：发送空白数据，等待 RX2 连续返回有效采样……\n');
ready = 0; warmStart = tic; warmUnder = 0; warmOver = 0;
while ready<10
    assert(toc(warmStart)<30,'30 秒内接收端未就绪，已停止本次实验。');
    u = tx(zeroBlock);
    [~,len,o] = rxObj();
    warmUnder = warmUnder + double(u~=0);
    warmOver = warmOver + double(o~=0);
    if len==chunk && o==0, ready=ready+1; else, ready=0; end
end
say(fid,'接收已就绪：连续 %d 块有效数据；开始 %.1f 秒空白缓冲。\n',ready,nLead/radioRate);

nRx = 0; nUnder = 0; nOver = 0; nEmpty = 0;
payloadUnder = 0; nextPrint = radioRate;
stage = 0; started = tic;
for p = 1:chunk:nTotal
    q = p+chunk-1;
    if stage==0 && p>nLead
        say(fid,'>>> 接收保持运行，现在开始发送正文："%s"（%.2f 秒）\n',userMsg,numel(txWave)/radioRate);
        stage = 1;
    elseif stage==1 && p>nLead+numel(txWave)
        say(fid,'>>> 正文已提交完毕，继续接收收尾数据约 %.1f 秒……\n',nTail/radioRate);
        stage = 2;
    end
    u = tx(txStream(p:q));
    [y,len,o] = rxObj();
    len = double(len); % SDRu 返回 uint32；转 double，避免秒数除法被整数取整。
    nUnder = nUnder + double(u~=0);
    nOver = nOver + double(o~=0);
    if u~=0 && q>nLead, payloadUnder=payloadUnder+1; end
    if len>0
        raw(nRx+(1:len)) = y(1:len);
        nRx = nRx+len;
    else
        nEmpty = nEmpty+1;
    end
    if q>=nextPrint || q==nTotal
        sent = min(max(q-nLead,0),numel(txWave))/radioRate;
        level = 20*log10(sqrt(mean(abs(double(y(1:max(len,1)))).^2))+eps);
        say(fid,'[%5.1fs] 正文 %5.1f/%4.1fs | 已收 %5.1fs | RX %6.1f dBFS | 欠载 %d 溢出 %d\n', ...
            toc(started),sent,numel(txWave)/radioRate,nRx/radioRate,level,nUnder,nOver);
        nextPrint = nextPrint+radioRate;
    end
end
% 先停止并释放射频设备，再进行耗时的重采样、画图和解码。
clear txCleanup
clear rxCleanup
say(fid,'收发结束，设备已释放：采集 %.2f 秒；正文阶段欠载 %d，接收溢出 %d。\n', ...
    nRx/radioRate,payloadUnder,nOver);
rawPower=mean(abs(double(raw(1:nRx))).^2);
rawPeak=max(abs(double(raw(1:nRx))));
rawClipped=nnz(abs(real(raw(1:nRx)))>=0.99 | abs(imag(raw(1:nRx)))>=0.99);
rx = double(raw(1:nRx));
clear raw txStream txWave
fsRx = S.fs;
captureMode = 'MATLAB B210 simultaneous TX/RX';
stats = struct('serial',serialNum,'options',opts,'sampleRate',radioRate, ...
    'txDigitalRmsDbFS',txRmsDbFS,'rxRawRmsDbFS',10*log10(rawPower), ...
    'rxRawPeakDbFS',20*log10(rawPeak),'rxClippedSamples',rawClipped, ...
    'rxSamples',nRx,'underruns',nUnder,'payloadUnderruns',payloadUnder, ...
    'overruns',nOver,'emptyReads',nEmpty,'warmupUnderruns',warmUnder,'warmupOverruns',warmOver);
capturePath = fullfile(outDir,'rx_capture.mat');
save(capturePath,'rx','fsRx','captureMode','stats');
if opts.CaptureOnly
    result=struct('capturePath',capturePath,'outputDirectory',outDir,'radioStats',stats);
    say(fid,'采集完成，交给展示窗口分析。\n');
    return;
end
say(fid,'接收数据已保存，开始时间同步、频率同步、解调和 RS 纠错……\n');
result = finishResult(rx,S,stats,fid,outDir,capturePath,opts.ShowPlots,opts.SyncMode,opts.DecoderMode,opts.DetectionMode);
end

function result = finishResult(rx,S,stats,fid,outDir,capturePath,showPlots,syncMode,decoderMode,detectionMode)
result = decodeFrame(rx,S,fid,syncMode,decoderMode,detectionMode);
result.snr = jt65_spectral_snr(rx,S,result.frameStartSeconds,result.frequencyOffset);
result.snr.pilot=jt65_pilot_snr(rx,S,result.frameStartSeconds,result.frequencyOffset);
result.outputDirectory = outDir;
result.capturePath = capturePath;
result.radioStats = stats;
result.transportClean = stats.payloadUnderruns==0 && stats.overruns==0 && stats.emptyReads==0;
result.passed = result.decoderAccepted && result.bitErrors==0 && result.transportClean;
save(fullfile(outDir,'result.mat'),'result');
say(fid,'\n=== 最终结果 ===\n');
say(fid,'发送："%s"\n收到："%s"\n',S.userMsg,result.message);
say(fid,'解调符号错误 %d/63；纠错后消息比特错误 %d/%d；BER %.6f\n', ...
    result.symbolErrors,result.bitErrors,result.payloadBitCount,result.ber);
if ~result.decoderAccepted
    say(fid,'未恢复：上述比特核对仅针对内部诊断候选，不是有效译码输出或有效 BER。\n');
end
V=result.validation;
say(fid,'接收链验收：逆格雷 %d/63 符号错误；解交织 %d/63 符号错误；RS 译码前 %d/378 比特错误，有效载荷译码后 %d/%d。\n', ...
    V.inverseGraySymbolErrors,V.deinterleavedSymbolErrors,V.codedBitErrors,result.bitErrors,result.payloadBitCount);
if strcmp(result.rsDiagnostics.mode,'joint7')
    d=result.rsDiagnostics;
    say(fid,'128 候选联合判决：%s；对数证据 %.2f / %.2f，对数优势 %.2f / %.2f。\n', ...
        d.reason,d.logEvidence,d.logEvidenceThreshold,d.logOdds,d.logOddsThreshold);
else
    say(fid,'RS 译码：%s；尝试 %d 次，使用 %d 个擦除。\n', ...
        result.rsDiagnostics.mode,result.rsDiagnostics.attempts,result.rsDiagnostics.usedErasures);
    say(fid,'RS 译码器状态：纠正符号数 %d（-1 表示译码失败）。\n',result.rsCorrectedSymbols);
end
say(fid,'频域 SNR 估计：%.2f dB（400 Hz 参考带宽）\n',result.snr.bandDb);
say(fid,'同步音估计 SNR：%.2f dB（2500 Hz 参考，局部平坦噪声假设）；近似 95%% 区间 [%.2f, %.2f] dB。\n', ...
    result.snr.pilot.snr2500Db,result.snr.pilot.snr2500IntervalDb);
say(fid,'等效信噪比估计：%.2f dB（%.0f Hz 参考带宽）\n',result.snr.fullBandDb,S.fs);
say(fid,'信号频带 [%.1f, %.1f] Hz；噪声取自本帧两侧频带。\n',result.snr.bandHz);
say(fid,'信号功率 %.2f dBFS；噪声密度 %.2f dBFS/Hz；两侧噪声密度相差 %.2f dB。\n', ...
    result.snr.signalDbFS,result.snr.noiseDensityDbFSPerHz,result.snr.noiseSideDifferenceDb);
say(fid,'P信号=信号带总功率-N0*%.1f；P噪声(B)=N0*B；SNR=10log10(P信号/P噪声)。\n',result.snr.bandwidthHz);
if ~isfinite(result.snr.bandDb)
    say(fid,'信号功率差不能分辨，SNR 标为 NaN。\n');
elseif abs(result.snr.noiseSideDifferenceDb)>3
    say(fid,'提示：两侧噪声谱差异较大，平坦噪声假设可能不成立。\n');
end
if ~result.transportClean
    say(fid,'本次有传输欠载或接收不连续，请结合日志检查，不能作为无丢样实验结果。\n');
elseif result.passed
    say(fid,'实验通过：采样连续，解码消息与发送消息一致。\n');
else
    say(fid,'消息仍有错误，请检查天线、收发增益和信号强度。\n');
end
if showPlots
    plotResult(rx,S,result,outDir);
    plotValidation(S,result,outDir);
end
say(fid,'结果已保存：%s\n',outDir);
end

function result = replayCapture(sourceDir,showPlots,syncMode,decoderMode,detectionMode)
sourceDir = char(sourceDir);
capturePath = fullfile(sourceDir,'rx_capture.mat');
assert(isfile(capturePath) && isfile(fullfile(sourceDir,'tx_reference.mat')), ...
    '该目录需要包含 rx_capture.mat 和 tx_reference.mat。');
C = load(capturePath); S = load(fullfile(sourceDir,'tx_reference.mat'));
assert(C.fsRx==S.fs,'接收文件与波形文件采样率不一致。');
outDir = fullfile(sourceDir,['analysis_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]);
mkdir(outDir);
fid = fopen(fullfile(outDir,'log.txt'),'w');
assert(fid>=0,'无法创建分析日志。');
logCleanup = onCleanup(@() fclose(fid));
say(fid,'=== 重分析保存的真机数据；本次不进行射频发射 ===\n');
say(fid,'采集目录：%s\n',sourceDir);
result = finishResult(double(C.rx(:)),S,C.stats,fid,outDir,capturePath,showPlots,syncMode,decoderMode,detectionMode);
end

function R = decodeFrame(rx,S,fid,syncMode,decoderMode,detectionMode)
fs = S.fs/2; L = S.nSamp/2;
x = decimate(real(rx),2,'fir')+1i*decimate(imag(rx),2,'fir');
tauMax = numel(x)-S.nSlot*L;
assert(tauMax>=0,'接收数据不足一帧，无法解码。');
if syncMode=="legacy"
    % 保留旧算法供相同采样、相同噪声种子的 A/B 对照。
    mix=x.*exp(-2i*pi*S.fSync*(0:numel(x)-1).'/fs);
    cs=[0;cumsum(mix)]; a=abs(cs(L+1:end)-cs(1:end-L));
    syncAmp=zeros(tauMax+1,1); dataAmp=syncAmp; starts=(1:tauMax+1).';
    for k=1:S.nSlot
        v=a(starts+(k-1)*L);
        if S.sync(k), syncAmp=syncAmp+v; else, dataAmp=dataAmp+v; end
    end
    scores=(syncAmp-dataAmp)./(syncAmp+dataAmp+eps);
    [score,pos]=max(scores); tau=pos-1;
    diagnostics=struct('method','legacy amplitude','timeSeconds',(0:tauMax).'/fs, ...
        'timeScores',scores,'threshold',0.5);
    say(fid,'时间同步（旧算法）：帧起点 %.4f 秒；同步得分 %.3f（不设同步门限）\n',tau/fs,score);
    cfo=refineFrequency(x,tau,S,fs,L,0,4);
else
    [tau,cfo,diagnostics]=jointSynchronize(x,S,fs,L);
    score=max(diagnostics.timeScores);
    say(fid,'时间/频率联合同步：帧起点 %.4f 秒，频偏 %+.3f Hz；能量得分 %.3f（不设同步门限）\n', ...
        tau/fs,cfo,score);
end
% threshold 保留为历史参考值，已不参与接收决策。
diagnostics.thresholdEnabled=false;
diagnostics.aboveReferenceThreshold=score>diagnostics.threshold;
say(fid,'同步得分仅供参考，使用最佳候选继续解调和 RS 译码。\n');
frame = x(tau+(1:S.nSlot*L));
nf = numel(frame);
f = (-floor(nf/2):ceil(nf/2)-1).'*fs/nf;
spec = abs(fftshift(fft(frame.*hann(nf))));
x = x.*exp(-2i*pi*cfo*(0:numel(x)-1).'/fs);
say(fid,'频率同步：频偏 %+.4f Hz\n',cfo);
correctedFrame = x(tau+(1:S.nSlot*L));
correctedSpec = abs(fftshift(fft(correctedFrame.*hann(nf))));
nearSync = abs(f-S.fSync)<=max(3,abs(cfo)+2);
scale = max(spec(nearSync));
diagnostics.frequencyOffsetHz=f(nearSync)-S.fSync;
diagnostics.frequencyBeforeDb=20*log10(spec(nearSync)/scale+eps);
diagnostics.frequencyAfterDb=20*log10(correctedSpec(nearSync)/scale+eps);
diagnostics.frequencyResolutionHz=fs/nf;
tones = S.fSync+S.df*((0:63)+2);
refs = exp(2i*pi*(0:L-1).'/fs*tones);
% 解调（非相干为原有行为；DetectionMode="coherent" 为新增相干检测）
[mlEnergy,sym,demodDiag]=jt65_demod_frame(x,tau,S,fs,L,detectionMode);
diagnostics.demodulator=demodDiag;
say(fid,'解调方式：%s\n',demodDiag.detectionMode);
if strcmp(demodDiag.detectionMode,'coherent')
    say(fid,'相干参考：|a|=%.3f，相位相干度 %.4f，全帧相位漂移 %.3f rad\n', ...
        abs(demodDiag.phaseReference),demodDiag.phaseCoherence,demodDiag.phaseDriftRad);
    say(fid,'定时残差估计：%.4f 抽样（%.2f ms），对τ偏差的相位斜率 %.5f rad/Hz\n', ...
        demodDiag.timingOffsetSamples,demodDiag.timingOffsetSeconds*1e3, ...
        demodDiag.timingOffsetRadPerHz);
end
back=sym; shift=bitshift(back,-1);
while any(shift), back=bitxor(back,shift); shift=bitshift(shift,-1); end
deinter=reshape(back,7,9).'; deinter=deinter(:);
bits=reshape(de2bi(deinter,6,'left-msb').',[],1);
if isfield(S,'payloadIndices'), payloadIndices=S.payloadIndices; else, payloadIndices=(1:numel(S.msgBits)).'; end
if decoderMode=="joint7" && isequal(payloadIndices(:),(1:7).')
    syncPos=find(S.sync==1); backgroundEnergy=zeros(64,numel(syncPos));
    for j=1:numel(syncPos)
        w=x(tau+(syncPos(j)-1)*L+(1:L));
        backgroundEnergy(:,j)=abs(refs'*w).^2;
    end
    [decoded,accepted,rsInfo]=jt65_decode7(mlEnergy,mean(backgroundEnergy,2));
    diagnostics.backgroundEnergy=backgroundEnergy;
    correctedCount=NaN; % 联合判决没有 RS 纠正符号数。
else
    requestedMode=decoderMode;
    if decoderMode=="joint7", decoderMode="hard"; end % 旧 72 比特格式不能限定为 128 候选。
    [decoded,correctedCount,rsInfo]=jt65_rs_decode(bits,mlEnergy,decoderMode);
    accepted=correctedCount>=0; rsInfo.requestedMode=char(requestedMode);
    % 相干检测偶尔会把 psi 锁到错误位置，此时符号错误反而高于非相干判决。
    % 解调器把非相干判决一并带回，主判决译不出时再试一次，保证相干路径只增不减。
    if ~accepted && isfield(demodDiag,'alternateSymbols') && ~isempty(demodDiag.alternateSymbols)
        symAlt=demodDiag.alternateSymbols;
        backAlt=symAlt; shiftAlt=bitshift(backAlt,-1);
        while any(shiftAlt), backAlt=bitxor(backAlt,shiftAlt); shiftAlt=bitshift(shiftAlt,-1); end
        deinterAlt=reshape(backAlt,7,9).'; deinterAlt=deinterAlt(:);
        bitsAlt=reshape(de2bi(deinterAlt,6,'left-msb').',[],1);
        [decodedAlt,countAlt,rsInfoAlt]=jt65_rs_decode(bitsAlt,mlEnergy,decoderMode);
        if countAlt>=0
            decoded=decodedAlt; correctedCount=countAlt; rsInfo=rsInfoAlt; accepted=true;
            rsInfo.requestedMode=char(requestedMode); rsInfo.fellBackToNoncoherent=true;
            sym=symAlt; back=backAlt; deinter=deinterAlt; bits=bitsAlt;
        end
    end
end
txt=char(bi2de(reshape(decoded,8,[]).','left-msb')).';
if isfield(S,'msgMode') && strcmp(S.msgMode,'bits7'), txt=char(decoded(payloadIndices).'+double('0')); end
if isfield(S,'msgMode') && strcmp(S.msgMode,'ascii7'), txt=char(bi2de(decoded(payloadIndices).','left-msb')); end
if ~accepted, txt='[未恢复]'; end
% 以下发送参考仅用于解码完成后的误差统计，不参与同步或接收判决。
encoder=comm.RSEncoder('BitInput',true,'CodewordLength',63,'MessageLength',12);
expectedCodedBits=encoder(S.msgBits);
expectedCodeSymbols=bi2de(reshape(expectedCodedBits,6,[]).','left-msb');
expectedInterleaved=reshape(expectedCodeSymbols,9,7).';
expectedInterleaved=expectedInterleaved(:);
validation=struct('inverseGraySymbols',back,'deinterleavedSymbols',deinter, ...
    'codedBits',bits,'expectedCodedBits',expectedCodedBits, ...
    'inverseGraySymbolErrors',nnz(back~=expectedInterleaved), ...
    'deinterleavedSymbolErrors',nnz(deinter~=expectedCodeSymbols), ...
    'codedBitErrors',nnz(bits~=expectedCodedBits), ...
    'codedBer',nnz(bits~=expectedCodedBits)/numel(bits));
diagnostics.mlEnergy=mlEnergy;
bitErr=nnz(decoded(payloadIndices)~=S.msgBits(payloadIndices));
R=struct('message',txt,'sentMessage',S.userMsg,'symbols',sym, ...
    'symbolErrors',nnz(sym~=S.gray),'decodedBits',decoded,'bitErrors',bitErr, ...
    'payloadIndices',payloadIndices,'payloadBitCount',numel(payloadIndices), ...
    'decodedPayloadBits',decoded(payloadIndices),'ber',bitErr/numel(payloadIndices),'frameStartSeconds',tau/fs,'syncScore',score, ...
    'frequencyOffset',cfo,'diagnostics',diagnostics,'validation',validation, ...
    'decoderAccepted',accepted,'rsCorrectedSymbols',correctedCount,'rsDiagnostics',rsInfo);
end

function [tau,cfo,D] = jointSynchronize(x,S,fs,L)
% 下变频/降采样仅用于同步搜索；数据解调仍使用原始分辨率采样。
% 对每个候选起点、频偏比较公开同步时隙和数据时隙的相关能量。
factor=16; fsSync=fs/factor; ls=L/factor;
y=decimate(x.*exp(-2i*pi*S.fSync*(0:numel(x)-1).'/fs),factor,'fir');
tauMax=min(numel(y)-S.nSlot*ls,floor((numel(x)-S.nSlot*L)/factor));
offsets=-20:0.5:20;
starts=(0:ls/16:tauMax).';
map=zeros(numel(starts),numel(offsets));
for j=1:numel(offsets)
    map(:,j)=syncEnergyScores(y,offsets(j),fsSync,ls,starts,S.sync);
end
[~,peak]=max(map(:)); [p,q]=ind2sub(size(map),peak);
tau=round(starts(p)*factor);
% 以联合搜索得到的频偏为中心，在整帧频谱中精化到约 0.02 Hz。
if S.df>20
    % 加速版首个数据音距同步音约 100 Hz，±20 Hz 内只有同步音。
    % 20 ms 符号的粗搜索峰较宽；全范围找主峰，避免锁到旁瓣。
    cfo=refineFrequency(x,tau,S,fs,L,0,20);
else
    cfo=refineFrequency(x,tau,S,fs,L,offsets(q),0.75);
end
cfo=max(-20,min(20,round(cfo*100)/100));
allStarts=(0:tauMax).';
scores=syncEnergyScores(y,cfo,fsSync,ls,allStarts,S.sync);
[~,p]=max(scores); tau=round(allStarts(p)*factor);
cfo=refineFrequency(x,tau,S,fs,L,cfo,0.15);
cfo=max(-20,min(20,round(cfo*100)/100));
scores=syncEnergyScores(y,cfo,fsSync,ls,allStarts,S.sync);
[~,p]=max(scores); tau=round(allStarts(p)*factor);
% 理想复白噪声下 Es/(Es+Ed) ~ Beta(63,63)。按全搜索网格作多重比较修正。
% 滤波、相关样本和实际干扰会偏离理想模型，因此另做噪声/干扰控制测试。
alpha=1e-3;
maxComparisons=(tauMax+1)*4001; % ±20 Hz、0.01 Hz 量化、全部时间候选
threshold=2*betaincinv(1-alpha/maxComparisons,nnz(S.sync),nnz(~S.sync))-1;
D=struct('method','joint energy','timeSeconds',allStarts/fsSync, ...
    'timeScores',scores,'threshold',threshold,'nominalNoiseFalseAlarm',alpha, ...
    'searchFrequencyOffsetsHz',offsets,'searchTimeSeconds',starts/fsSync, ...
    'searchScoreMap',map,'searchRangeHz',20,'maxComparisons',maxComparisons);
end

function score = syncEnergyScores(y,cfo,fs,L,starts,sync)
mix=y.*exp(-2i*pi*cfo*(0:numel(y)-1).'/fs);
cs=[0;cumsum(mix)]; energy=abs(cs(L+1:end)-cs(1:end-L)).^2;
slots=energy(starts+1+(0:numel(sync)-1)*L);
es=sum(slots(:,sync==1),2); ed=sum(slots(:,sync==0),2);
score=(es-ed)./(es+ed+realmin);
end

function cfo = refineFrequency(x,tau,S,fs,L,center,halfWidth)
frame=x(tau+(1:S.nSlot*L)); n=numel(frame);
f=(-floor(n/2):ceil(n/2)-1).'*fs/n;
spec=abs(fftshift(fft(frame.*hann(n))));
search=find(abs(f-S.fSync-center)<=halfWidth);
[~,j]=max(spec(search)); cfo=f(search(j))-S.fSync;
end

function plotResult(rx,S,R,outDir)
fig=figure('Name','实验三四：收发、同步与信噪比','Position',[50 50 1400 1020],'Color','w');
tiledlayout(3,2,'TileSpacing','compact','Padding','compact');
sgtitle(sprintf('JT65 真机实验 | 收到 "%s" | SNR %.2f dB（400 Hz） | BER %.4f', ...
    strtrim(R.message),R.snr.bandDb,R.ber),'FontSize',16,'FontWeight','bold','Interpreter','none');
nexttile;
stairs((0:S.nSlot-1)*S.nSamp/S.fs,S.freq,'LineWidth',1); grid on;
xlim([0 S.nSlot*S.nSamp/S.fs]);
xlabel('发送时间 (s)'); ylabel('频率 (Hz)'); title(['① 发送波形：' S.userMsg],'Interpreter','none');
nexttile;
[~,f,t,p]=spectrogram(rx,4096,3072,8192,S.fs);
band=f>=1150*S.fs/11025 & f<=1550*S.fs/11025;
imagesc(t,f(band),10*log10(p(band,:)+eps)); axis xy; colorbar;
xlabel('接收时间 (s)'); ylabel('频率 (Hz)'); title('② 接收瀑布图');
nexttile;
D=R.diagnostics;
plot(D.timeSeconds,D.timeScores,'LineWidth',1); hold on; grid on;
plot(R.frameStartSeconds,R.syncScore,'ro','MarkerFaceColor','r');
xline(R.frameStartSeconds,':r');
xlabel('候选帧起点 (s)'); ylabel('同步得分');
title(sprintf('③ 时间同步（无门限）：候选起点 %.4f s，峰值 %.3f',R.frameStartSeconds,R.syncScore));
ylim([min(-0.1,min(D.timeScores)-0.05) 1.05]);
nexttile;
plot(D.frequencyOffsetHz,D.frequencyBeforeDb,'LineWidth',1.2); hold on;
plot(D.frequencyOffsetHz,D.frequencyAfterDb,'--','LineWidth',1.2); grid on;
xline(0,':k','理想同步音','LabelVerticalAlignment','bottom','HandleVisibility','off');
xlim([-1 1]*max(0.5,abs(R.frequencyOffset)+0.3)); ylim([-65 5]);
xlabel(sprintf('相对 %.1f Hz 的频率偏移 (Hz)',S.fSync)); ylabel('归一化幅度 (dB)');
legend('校正前','校正后','Location','southwest');
title({sprintf('④ 频率同步：估计频偏 %+.4f Hz',R.frequencyOffset), ...
    sprintf('FFT 频率间隔 %.4f Hz；小于此间隔的频偏需谨慎解释',D.frequencyResolutionHz)});
nexttile;
Q=R.snr;
plot(Q.frequencyHz,10*log10(Q.framePsd+eps),'LineWidth',1.1); hold on;
plot(Q.frequencyHz,10*log10(Q.noisePsd+eps),'LineWidth',1.1); grid on;
xlim(Q.displayBandHz); xlabel('频率 (Hz)'); ylabel('功率谱密度 (dBFS/Hz)');
legend('帧内：信号 + 噪声','带外估计噪声密度','Location','northeast');
title({sprintf('⑤ 频域 SNR = %.2f dB（400 Hz 参考）',Q.bandDb), ...
    sprintf('信号 %.2f dBFS，噪声 %.2f dBFS；%.0f Hz 等效 SNR %.2f dB', ...
    Q.signalDbFS,Q.noiseDbFS,S.fs,Q.fullBandDb)});
nexttile;
stem(0:62,S.gray,'filled'); hold on; stem(0:62,R.symbols,'x'); grid on;
legend('发送符号','接收符号'); xlabel('符号序号'); ylabel('符号值');
title(sprintf('⑥ 解调：符号错误 %d/63，有效比特错误 %d/%d',R.symbolErrors,R.bitErrors,R.payloadBitCount));
axesList=findall(fig,'Type','axes');
for k=1:numel(axesList)
    axesList(k).Toolbar.Visible='off';
    axesList(k).FontSize=10;
end
exportgraphics(fig,fullfile(outDir,'result.png'),'Resolution',150);
end

function plotValidation(S,R,outDir)
fig=figure('Name','JT65 接收链验收：同步、解调、译码与 BER', ...
    'Position',[70 50 1440 1080],'Color','w');
tiledlayout(3,2,'TileSpacing','compact','Padding','compact');
sgtitle(sprintf('JT65 接收链验收 | 真机采集 | 发送 "%s" → 收到 "%s"', ...
    S.userMsg,strtrim(R.message)),'FontSize',16,'FontWeight','bold','Interpreter','none');
D=R.diagnostics; V=R.validation;
nexttile;
plot(D.timeSeconds,D.timeScores,'LineWidth',1.2); hold on; grid on;
plot(R.frameStartSeconds,R.syncScore,'ro','MarkerFaceColor','r');
xlabel('候选帧起点 (s)'); ylabel('公开同步序列匹配得分');
title(sprintf('① 时间同步（无门限）：%.4f s，得分 %.3f',R.frameStartSeconds,R.syncScore));
nexttile;
plot(D.frequencyOffsetHz,D.frequencyBeforeDb,'LineWidth',1.2); hold on;
plot(D.frequencyOffsetHz,D.frequencyAfterDb,'--','LineWidth',1.2); grid on;
xline(0,':k','HandleVisibility','off');
xlim([-1 1]*max(0.5,abs(R.frequencyOffset)+0.3)); ylim([-65 5]);
xlabel('相对同步音的频率偏移 (Hz)'); ylabel('归一化幅度 (dB)');
legend('校正前','校正后','Location','southwest');
title({sprintf('② 频率同步：估计 %+.4f Hz',R.frequencyOffset), ...
    sprintf('FFT 间隔 %.4f Hz；同步方式：%s',D.frequencyResolutionHz,D.method)});
nexttile;
relativeEnergy=D.mlEnergy./max(D.mlEnergy,[],1);
imagesc(1:63,0:63,10*log10(relativeEnergy+eps)); axis xy;
clim([-35 0]); colorbar; hold on;
plot(1:63,R.symbols,'w.','MarkerSize',6);
xlabel('数据符号序号'); ylabel('64 个候选符号');
title({'③ 非相干最大似然解调：逐列选择最大相关能量', ...
    sprintf('颜色：相对本列最大能量 (dB)；判决错误 %d/63',R.symbolErrors)});
nexttile; axis off;
text(0,0.95,'④ 解码各阶段核对','FontSize',13,'FontWeight','bold');
rows={ ...
    sprintf('解格雷映射：63 个 6-bit 符号；错误 %d/63',V.inverseGraySymbolErrors), ...
    sprintf('解交织：恢复 RS 码字符号顺序；错误 %d/63',V.deinterleavedSymbolErrors), ...
    sprintf('解信道编码：RS(63,12)，378 bit → 72 bit'), ...
    sprintf('RS 译码前：%d/378 bit，BER = %.6f',V.codedBitErrors,V.codedBer), ...
    sprintf('有效载荷：%d/%d bit 错误，BER = %.6f',R.bitErrors,R.payloadBitCount,R.ber), ...
    '核对参考仅用于统计；接收判决不使用发送消息。'};
if strcmp(R.rsDiagnostics.mode,'joint7')
    d=R.rsDiagnostics;
    rows{3}='整帧联合判决：全部 128 个七比特码字；已知补零格式';
    rows{4}=sprintf('对数证据 %.1f / %.1f；对数优势 %.1f / %.1f', ...
        d.logEvidence,d.logEvidenceThreshold,d.logOdds,d.logOddsThreshold);
end
if ~R.decoderAccepted, rows{5}='未恢复；诊断候选不计入有效 BER。'; end
for k=1:numel(rows)
    text(0,0.82-(k-1)*0.135,rows{k},'FontSize',11,'Interpreter','none');
end
nexttile;
idx=R.payloadIndices;
bitImage=[double(S.msgBits(idx).');double(R.decodedBits(idx).');double(R.decodedBits(idx).'~=S.msgBits(idx).')];
imagesc(1:R.payloadBitCount,1:3,bitImage); clim([0 1]);
colormap(gca,[0.94 0.96 0.98;0.1 0.38 0.68]);
yticks(1:3); yticklabels({'发送比特','译码比特','错误位置'});
xlabel('有效载荷比特序号（不含 RS 补位）');
cb=colorbar; cb.Ticks=[0 1]; cb.TickLabels={'0','1'};
title(sprintf('⑤ 输出误比特率：BER = %d / %d = %.6f',R.bitErrors,R.payloadBitCount,R.ber));
if ~R.decoderAccepted, title('⑤ 候选比特核对 · 未恢复，无有效 BER'); end
nexttile; axis off;
text(0,0.95,'⑥ 接收处理流程与本帧结论','FontSize',13,'FontWeight','bold');
lines={ '接收 IQ → 时间同步 → 频率估计与校正', ...
    '→ 64 音最大似然判决 → 解格雷映射', ...
    '→ 解交织 → RS 译码 → 消息与 BER', ...
    sprintf('带内 SNR：%.2f dB（400 Hz）',R.snr.bandDb), ...
    sprintf('采集连续：%s；本帧验收通过：%s',string(R.transportClean),string(R.passed)), ...
    '本帧零错误仅代表本次观测；不代表长期误码率为零。'};
if strcmp(R.rsDiagnostics.mode,'joint7')
    lines{2}='→ 保留 64 音软能量 → 比较全部 128 个码字';
    lines{3}='→ 证据与候选优势检验 → 输出消息或未恢复';
end
for k=1:numel(lines)
    text(0,0.82-(k-1)*0.135,lines{k},'FontSize',11,'Interpreter','none');
end
axesList=findall(fig,'Type','axes');
for k=1:numel(axesList)
    axesList(k).Toolbar.Visible='off'; axesList(k).FontSize=10;
end
exportgraphics(fig,fullfile(outDir,'acceptance.png'),'Resolution',150);
end

function say(fid,varargin)
msg=sprintf(varargin{:});
fprintf('%s',msg);
fprintf(fid,'%s',msg);
end
