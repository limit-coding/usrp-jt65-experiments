% 实验4：JT65 接收端 —— 真机采集、时间同步、频率同步、最大似然解调、解码
%
% 单台 B210：ch1 TX/RX 发射，ch1 RX2 接收；有线回环需在两口间串接衰减器。
%
% 单台 B210 + MATLAB R2025b 一键收发、解码：运行 exp34_jt65_live("hello")。
% 本脚本也可读取 python/jt65_one_b210_loopback.py 生成的历史采集文件。
% useCapturedFile=false 可恢复原来的仿真模式；单独 useUSRP=true 时须有外部发射机。
%
% 流程
%   1) 取接收信号（默认读取采集文件；useUSRP = true 则 B210 ch2 单独实采）
%   2) 数字化：低通 + 2 倍降采样，11025 -> 5512.5 Hz
%   3) 时间同步：在整段录制里粗搜 + 细化，找帧起始
%   4) 频率同步：帧区间 FFT 找同步音峰，估计并校正频偏
%   5) 最大似然解调：与本地 64 个候选音的参考频谱比欧式距离
%   6) 解码：解格雷 -> 解交织 -> 解 RS -> 还原 ASCII
%   7) 输出频谱图、瀑布图、误比特率
clear; clc; rng default;

%% ---------------- 参数 ----------------
fs     = 11025;      % 原采样率 (Hz)
fsDec  = fs/2;       % 2 倍降采样后 5512.5 Hz
nSamp  = 4096;       % 原速率下每时隙点数
L      = nSamp/2;    % 降采样后每时隙 2048 点（= 1 个时隙长度）
nSlot  = 126;
fSync  = 1270.5;
df     = 2.6917;
mSub   = 1;
thresh = 0.5;        % 同步音/数据时隙能量对比的门限
outDir = fullfile(fileparts(mfilename('fullpath')),'..','..','data');

%% ---------------- 1. 取接收信号 ----------------
useCapturedFile = true;  % true -> 读取单台 B210 同时收发的采集文件
useUSRP    = false;      % true -> 单独用 B210 采集（要求另有发射机）
snrDb      = 0;          % 回环信噪比 (dB)
recSeconds = 60;         % 实采时长 (s)，必须 >= 一帧 46.81 s
rxFreq     = 435e6;      % 接收中心频率 (Hz)，要和 exp3 的 txFreq 一致
rxGain     = 20;         % 接收增益 (dB)，两副天线离得近，从小往大调
usrpRate   = 204800;     % = 61.44e6 / 300
rawFile    = fullfile(outDir,'jt65_rx_raw.mat');
captureFile = fullfile(outDir,'jt65_one_b210_rx.mat');

matFile = fullfile(outDir,'jt65_wave.mat');
assert(exist(matFile,'file')==2, '找不到 %s，请先运行 exp3_jt65_tx_waveform.m', matFile);
S = load(matFile);

if useCapturedFile
    assert(exist(captureFile,'file')==2, '找不到 %s，请先运行 python/jt65_one_b210_loopback.py', captureFile);
    C = load(captureFile);
    assert(isfield(C,'fsRx') && C.fsRx==fs, '采集文件采样率不是 %d Hz', fs);
    rx = double(C.rx(:));
    recSeconds = numel(rx)/fs;
    if isfield(C,'captureMode')
        mode = char(C.captureMode);
    else
        mode = '未注明';
    end
    fprintf('读取采集文件（%s）：%d 点 (%.2f s @ %d Hz)\n', mode, numel(rx), recSeconds, fs);
elseif useUSRP
    % 自动识别在线的 B210（347380A 或 3237C62 都可以）
    ri = findsdru;
    b210 = ri(strcmp({ri.Platform},'B210') & strncmp({ri.Status},'Success',7));
    assert(~isempty(b210), '没有检测到在线的 B210。请检查 USB3 连接，并先关闭其他占用 USRP 的 MATLAB/GNU Radio 进程。');
    serialNum = b210(1).SerialNum;
    fprintf('检测到 B210：%s\n', serialNum);
    rx = jt65_capture(serialNum, rxFreq, rxGain, recSeconds, usrpRate);
    fprintf('USRP 实采：%d 点 (%.1f s @ %d Hz)，ch2 接收\n', ...
            numel(rx), numel(rx)/usrpRate, usrpRate);
    save(rawFile,'rx','rxFreq','rxGain','usrpRate','recSeconds');
    fprintf('原始 IQ 已存 %s\n', rawFile);
else
    rx = awgn(S.wave, snrDb, 'measured');
    fprintf('回环模式：实验3 波形 + %.1f dB 噪声\n', snrDb);
end

%% ---------------- 2. 数字化：低通 + 2 倍降采样 ----------------
% 实部虚部分别滤波再合成，避免 decimate 对复数输入的行为差异。
% decimate 用 'fir' 是零相位（filtfilt），不引入群延迟。
rxd = decimate(real(rx),2,'fir') + 1i*decimate(imag(rx),2,'fir');
rxd = [rxd; zeros(L,1)];    % 补一个时隙，保证帧起始能搜到录制末尾
fprintf('降采样：%d -> %d 点 (%.1f Hz)\n', numel(rx), numel(rxd), fsDec);

%% ---------------- 3. 时间同步：在整段录制里搜帧起始 ----------------
% 回环时帧起始就在 0 附近；实采时它落在录制的哪个位置是未知的。
% 逐点搜太慢（60 s 录制有 7 万多个候选位置），所以先粗搜再细化。
% 在每个候选起点，比较同步时隙与数据时隙在 1270.5 Hz 的相干幅度。
% 弱信号时，原来的相邻窗相关值接近纯噪声底，无法可靠检出。
syncPos = find(S.sync==1);
dataPos = find(S.sync==0);
tauMax  = numel(rxd) - nSlot*L;
stride  = 256;
fprintf('帧起始搜索：0..%d 点 (%.1f s)，粗搜步长 %d\n', tauMax, tauMax/fsDec, stride);

best = -inf; tauHat = 0;
for tau = 0:stride:tauMax
    sc = syncScore(rxd, tau, syncPos, dataPos, L, fsDec, fSync);
    if sc > best, best = sc; tauHat = tau; end
end
for tau = max(0,tauHat-stride) : min(tauMax, tauHat+stride)
    sc = syncScore(rxd, tau, syncPos, dataPos, L, fsDec, fSync);
    if sc > best, best = sc; tauHat = tau; end
end
bestScore = best;
fprintf('时间同步：偏移 %d 点 (%.4f s)，同步得分 %.3f\n', tauHat, tauHat/fsDec, bestScore);
if bestScore > thresh
    fprintf('  同步检测通过（> 门限 %.2f）\n', thresh);
else
    error('时间同步失败：同步得分 %.3f <= 门限 %.2f。请检查发射端、天线、频率和增益。', bestScore, thresh);
end

%% ---- 关于定时精度 ----
% 试过用"伪随机图样×同步音"做匹配滤波来细化定时，结果是错的，原因是：
% JT65 是相位连续 FSK，各同步时隙的起始相位不同，而参考序列每个时隙都从
% 零相位起振，63 段相关值相位随机、互相抵消。
% 更根本的是：同步音在整个时隙内都存在，落在时隙内任何位置的采样点能量都高，
% 所以时隙内的定时精度本质上提不出来 —— 这正是课件写"同步精度 0.03 s"
% （5512.5 Hz 下约 165 点，8% 个时隙）的原因。
% 好在这不影响解调：各音调在一个完整时隙上正交（1270.5 Hz × 0.3715 s = 472
% 个整周期，间隔 2.6917 Hz × 0.3715 s = 1 个整周期），只要窗口大致落在时隙内，
% 最大似然判决就是对的。

%% ---------------- 4. 频率同步 ----------------
% 只在检测到的帧区间上估频偏，避免录制里的纯噪声段把峰值带偏。
frame = rxd(tauHat + (1:nSlot*L));
Nf    = numel(frame);
X     = abs(fftshift(fft(frame .* hann(Nf), Nf)));
[~, pos] = max(X);
fre   = (pos - Nf/2)/Nf * fsDec;
d_fre = fre - fSync;
fprintf('频率同步：峰值 %.3f Hz，频偏 %+.3f Hz\n', fre, d_fre);
n = (0:numel(rxd)-1).';
rxd = rxd .* exp(-2i*pi*d_fre*n/fsDec);             % 频偏校正

%% ---------------- 5. 最大似然解调 ----------------
t  = (0:L-1).'/fsDec;
fN = fSync + df*((0:63).'+2)*mSub;                  % 64 个候选音 (N = 0..63)
RefSpec = abs(fft(exp(1i*2*pi*t*fN.')));            % L x 64
RefSpec = RefSpec ./ vecnorm(RefSpec);              % 归一化，消除幅度差异

symHat  = zeros(63,1);
for j = 1:63
    s0 = tauHat + (dataPos(j)-1)*L + 1;
    w  = rxd(s0 + (0:L-1).');                       % L x 1 列向量
    wSpec = abs(fft(w));
    wSpec = wSpec / (norm(wSpec)+eps);
    % 课件写的是 sum((spectrum.' - spectrum_theory).^2)：对复数直接平方
    % 得到的不是距离。这里改成幅度谱的欧式距离，且对相位和幅度不敏感。
    d2 = sum((wSpec - RefSpec).^2, 1);
    [~, Nhat] = min(d2);
    symHat(j) = Nhat - 1;
end
symErr = nnz(symHat ~= S.gray);
fprintf('解调：符号错误 %d / 63\n', symErr);

%% ---------------- 6. 解码：解格雷 -> 解交织 -> 解 RS -> ASCII ----------------
back = symHat;                                        % 格雷逆映射
shift = bitshift(back,-1);
while any(shift), back = bitxor(back,shift); shift = bitshift(shift,-1); end
deinter = reshape(back,7,9).'; deinter = deinter(:);  % 解交织（与 homework2 一致）
rxBits  = reshape(de2bi(deinter,6,'left-msb').',[],1);
decoder = comm.RSDecoder('BitInput',true,'CodewordLength',63,'MessageLength',12);
msgHat  = decoder(rxBits);
nBitErr = nnz(msgHat ~= S.msgBits);
ber     = nBitErr/numel(S.msgBits);

% 72 bit -> 9 个 ASCII 字符
txtHat = char(bi2de(reshape(msgHat,8,[]).','left-msb')).';
if isfield(S,'userMsg'), txtSent = S.userMsg; else, txtSent = '(未知)'; end

%% ---------------- 7. 结果 ----------------
fprintf('\n=== 实验4 结果 ===\n');
fprintf('时间同步偏移 : %d 点 (%.4f s)\n', tauHat, tauHat/fsDec);
fprintf('频偏         : %+.3f Hz\n', d_fre);
fprintf('符号错误     : %d / 63\n', symErr);
fprintf('消息比特错误 : %d / %d\n', nBitErr, numel(S.msgBits));
fprintf('误比特率     : %.4f\n', ber);
fprintf('发送消息     : "%s"\n', txtSent);
fprintf('解出消息     : "%s"\n', txtHat);

%% ---------------- 8. 频谱图 + 瀑布图 ----------------
f2 = figure('Name','实验4 接收结果','Position',[100 100 1000 820]);

% (a) 接收信号频谱：帧区间的 FFT，能看到同步音和 64 个数据音
subplot(3,1,1);
Nfft = 2^16;
Xa   = abs(fftshift(fft(frame .* hann(Nf), Nfft)));
fax  = (-Nfft/2:Nfft/2-1).'/Nfft*fsDec;
plot(fax, 20*log10(Xa/max(Xa)+eps), 'LineWidth', 0.8); grid on;
xlim([1200 1520]); ylim([-60 5]);
xlabel('频率 (Hz)'); ylabel('归一化幅度 (dB)');
title(sprintf('接收信号频谱（同步音 %.1f Hz，数据音间隔 %.4f Hz）', fSync, df));

% (b) 瀑布图：整段录制，能看出帧的时间和频率结构
subplot(3,1,2);
[~, fAx, tAx, P] = spectrogram(rxd(1:min(end,round(recSeconds*fsDec))), ...
                               2048, 1920, 4096, fsDec);
imagesc(tAx, fAx, 10*log10(abs(P)+eps)); axis xy;
ylim([1150 1550]); xlabel('时间 (s)'); ylabel('频率 (Hz)');
title('接收瀑布图');
colorbar;

% (c) 解调符号对比
subplot(3,1,3);
stem(0:62, S.gray, 'filled'); hold on; stem(0:62, symHat, 'x'); grid on;
legend('发送符号','解调符号'); xlabel('符号序号'); ylabel('6bit 符号值');
title(sprintf('解调符号对比（错误 %d 个，BER = %.4f）', symErr, ber));

saveas(f2, fullfile(outDir,'jt65_demod.png'));
fprintf('图已保存 %s\n', fullfile(outDir,'jt65_demod.png'));

%% ---------------- 局部函数 ----------------
function s = syncScore(rxd, tau, syncPos, dataPos, L, fsDec, fSync)
% 同步音在 sync 时隙出现、在 data 时隙消失；逐时隙投影抑制宽带噪声。
persistent ref
if isempty(ref), ref = exp(-2i*pi*fSync*(0:L-1).'/fsDec); end
idx = tau + (0:125)*L + 1;
W = rxd(idx + (0:L-1).');
a = abs(ref.'*W);
syncAmp = mean(a(syncPos));
dataAmp = mean(a(dataPos));
s = (syncAmp-dataAmp)/(syncAmp+dataAmp+eps);
end

function rx = jt65_capture(serialNum, fc, gain, seconds, usrpRate)
% 从 B210 ch2 采集一段信号。B210 设不了 11025 Hz，所以按 204800 Hz 采，
% 采完再重采样到 11025 Hz（204800/11025 = 8192/441）。
rxObj = comm.SDRuReceiver('Platform','B210','SerialNum',serialNum, ...
    'CenterFrequency',fc,'Gain',gain, ...
    'MasterClockRate',61.44e6,'DecimationFactor',300, ...
    'SamplesPerFrame',usrpRate/10,'OutputDataType','double', ...
    'ChannelMapping',2);                        % ch2 接收，ch1 留给发射

n = ceil(seconds*usrpRate);
buf = complex(zeros(n,1));
p = 0; nOver = 0; nextMark = 10;
fprintf('开始采集 %.1f s（ch2）...\n', seconds);
t0 = tic;
while p < n
    [y, len, over] = rxObj();
    nOver = nOver + over;
    if len > 0
        take = min(len, n-p);
        buf(p+1:p+take) = y(1:take);
        p = p + take;
    end
    if p/usrpRate >= nextMark
        fprintf('  %.0f / %.0f s\n', p/usrpRate, seconds);
        nextMark = nextMark + 10;
    end
end
release(rxObj);
fprintf('采集完成：%.1f s，缓冲溢出 %d 次\n', toc(t0), nOver);
rx = resample(buf, 441, 8192);                  % 204800 -> 11025 Hz
end
