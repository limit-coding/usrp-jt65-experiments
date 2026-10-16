% 实验3：JT65 发射端 —— 自定义消息编码、同步序列插入、相位连续 FSK 调制、真机发射
% 单台 B210 一键完成实验三、四：运行 exp34_jt65_live("hello")。
%
% 输入：userMsg 自定义文本（最多 9 个 ASCII 字符），或 'random' 随机 72 bit
% 输出：data/jt65_wave.mat —— 一帧完整 JT65 基带波形，供实验4 接收使用
%       doTransmit = true 时还会经 B210 ch1 真正发射
%
% 流程
%   1) 编码链路：72 bit -> RS(63,12) -> 交织 -> 格雷映射 -> 63 个 6bit 符号
%   2) 按 Taylor Fig.3 的 126 位伪随机序列插入同步音
%   3) 相位连续 FSK 调制，生成一帧基带波形
%   4) 时域图 + 瀑布图
%   5) 存盘供实验4 使用
%   6) 可选的单独真机发射（默认关闭）
%
% 参数依据 Taylor, K1JT, "The JT65 Communications Protocol" (2002)：
%   每时隙 4096 点 @ 11025 Hz，一帧 126 时隙，共 46.81 s；
%   同步音 1270.5 Hz；数据音 f = 1270.5 + 2.6917(N+2)m Hz，
%   m = 1 / 2 / 4 对应 A / B / C 子模式。
clear; clc; rng default;

%% ---------------- 0. 自定义消息 ----------------
% JT65 一帧恰好 72 bit = 9 个 ASCII 字符。不足 9 字符用空格补齐。
msgMode = 'text';            % 'text' 用下面的 userMsg / 'random' 随机 72 bit
userMsg = 'hello';           % 想发什么就改这里

if strcmp(msgMode,'text')
    txt = char(userMsg);
    assert(numel(txt) <= 9, '消息最多 9 个 ASCII 字符（9 字符 x 8 bit = 72 bit）');
    txt = [txt, repmat(' ', 1, 9-numel(txt))];            % 补空格到 9 字符
    msgBits = reshape(de2bi(double(txt),8,'left-msb').',[],1);   % 9x8 -> 72x1
    fprintf('消息 "%s" -> 72 bit（ASCII，空格补齐到 9 字符）\n', userMsg);
    fprintf('  十六进制：%s\n', sprintf('%02X ', txt));
else
    msgBits = randi([0 1],72,1);
    fprintf('消息：随机 72 bit\n');
end

%% ---------------- 参数 ----------------
fs     = 11025;      % 基带采样率 (Hz)
nSamp  = 4096;       % 每时隙采样点数 -> 0.3715 s
nSlot  = 126;        % 一帧 = 63 同步 + 63 数据
fSync  = 1270.5;     % 同步音 (Hz)
df     = 2.6917;     % 相邻音调间隔 (Hz)
mSub   = 1;          % 子模式：A=1 / B=2 / C=4
outDir = fullfile(fileparts(mfilename('fullpath')),'..','..','data');
if ~exist(outDir,'dir'), mkdir(outDir); end

%% ---------------- 1. 实验2 的编码链路：得到 63 个 6bit 信道符号 ----------------
enc       = comm.RSEncoder('BitInput',true,'CodewordLength',63,'MessageLength',12);
codedBits = enc(msgBits);                                % 378 bit = 63 个 6bit 符号
s         = bi2de(reshape(codedBits,6,[]).','left-msb'); % 63 个 0..63
inter     = reshape(s,9,7).'; inter = inter(:);          % 交织：按行写入 7x9，再按列读出
gray      = bitxor(inter,floor(inter/2));                % 格雷映射
fprintf('编码完成：%d 个 6bit 信道符号\n', numel(gray));

%% ---------------- 2. 同步序列（Taylor Fig.3，126 bit，恰好 63 个 1）----------------
sync = [1,0,0,1,1,0,0,0,1,1,1,1,1,1,0,1,0,1,0,0,0,1,0,1,1,0,0,1,0,0, ...
        0,1,1,1,0,0,1,1,1,1,0,1,1,0,1,1,1,1,0,0,0,1,1,0,1,0,1,0,1,1, ...
        0,0,1,1,0,1,0,1,0,1,0,0,1,0,0,0,0,0,0,1,1,0,0,0,0,0,0,0,1,1, ...
        0,1,0,0,1,0,1,1,0,1,0,1,0,1,0,0,1,1,0,0,1,0,0,1,0,0,0,0,1,1, ...
        1,1,1,1,1,1].';
assert(numel(sync)==nSlot, '同步序列必须是 126 bit');
assert(nnz(sync)==63,      '同步序列必须恰好 63 个 1');
assert(nnz(sync==0)==63,   '同步序列必须恰好 63 个 0');

%% ---------------- 3. 组装 126 个时隙的频率 ----------------
% sync=1 的时隙发同步音；sync=0 的时隙依次发 63 个数据符号音
toneIdx = zeros(nSlot,1);    % 音调索引，0 表示同步音
p = 0;
for k = 1:nSlot
    if sync(k)==1
        toneIdx(k) = 0;
    else
        p = p + 1;
        toneIdx(k) = gray(p) + 2;      % 符号 N -> 音调索引 N+2
    end
end
assert(p==63, '数据符号必须恰好用完 63 个');
freq = fSync + df*toneIdx*mSub;        % 每个时隙的瞬时频率 (Hz)

%% ---------------- 4. 相位连续 FSK 调制 ----------------
% 时隙之间的相位必须连续（CPFSK）。若每个时隙都从零相位起振，
% 频谱会因相位跳变而展宽，接收端同步和解调都会变差。
t = (0:nSamp-1).'/fs;
wave = zeros(nSlot*nSamp,1);
phaseAcc = 0;
for k = 1:nSlot
    idx = (k-1)*nSamp + (1:nSamp);
    wave(idx) = exp(1i*(2*pi*freq(k)*t + phaseAcc));
    phaseAcc = mod(phaseAcc + 2*pi*freq(k)*nSamp/fs, 2*pi);   % 相位累加
end
fprintf('波形生成完成：%d 点，时长 %.2f s\n', numel(wave), numel(wave)/fs);

%% ---------------- 5. 时域图 + 瀑布图 ----------------
% 直接画整段（或 6 个时隙 = 24576 点）在 900 px 宽下约 27 点/像素，只剩一片黑，
% 什么都看不出来。载波是 1270.5 Hz，一个时隙 0.3715 s 里有 472 个周期，
% 想在一个图里同时看清"全帧结构"和"载波周期"本来就不可能。
% 所以按两个尺度分开画：
%   (a) 全帧尺度 —— 画每时隙的瞬时频率（126 个点），结构一目了然
%   (b) 局部尺度 —— 只画跨时隙边界的 ±6 ms，能看见载波周期和相位连续
f1 = figure('Name','JT65 基带波形','Position',[100 100 900 780]);

% (a) 全帧频率台阶图：一眼看出 63 同步 + 63 数据的分布
subplot(3,1,1);
stairs((0:nSlot-1).'*nSamp/fs, freq, 'LineWidth', 0.8); grid on;
xlim([0 nSlot*nSamp/fs]); ylim([min(freq)-30, max(freq)+30]);
xlabel('时间 (s)'); ylabel('瞬时频率 (Hz)');
title('全帧频率台阶图：同步时隙恒在 1270.5 Hz，数据时隙依次取音');

% (b) 局部波形：取第一个"频率发生变化"的时隙交界，前后各 6 ms
subplot(3,1,2);
kb    = find(diff(freq)~=0, 1);          % 第一个有频率跳变的交界
nHalf = round(0.006*fs);                 % 6 ms
seg   = (kb*nSamp - nHalf + 1) : (kb*nSamp + nHalf);
plot((seg-1)/fs, real(wave(seg)), 'LineWidth', 1.2); grid on; hold on;
xline(kb*nSamp/fs, 'r--', 'LineWidth', 1);
xlabel('时间 (s)'); ylabel('实部');
title(sprintf('时隙交界处 ±6 ms：%.1f Hz -> %.1f Hz，交界两侧相位连续', ...
              freq(kb), freq(kb+1)));

% (c) 瀑布图
subplot(3,1,3);
[~, fAx, tAx, P] = spectrogram(wave, 1024, 960, 2048, fs);
imagesc(tAx, fAx/1000, 10*log10(abs(P)+eps)); axis xy;
ylim([0.9 1.8]); xlabel('时间 (s)'); ylabel('频率 (kHz)');
title('瀑布图（同步音恒在 1270.5 Hz，数据音在其上方）');
colorbar;

saveas(f1, fullfile(outDir,'jt65_waveform.png'));
fprintf('图已保存 %s\n', fullfile(outDir,'jt65_waveform.png'));

%% ---------------- 6. 存盘（供实验4 使用）----------------
matFile = fullfile(outDir,'jt65_wave.mat');
save(matFile, 'wave','fs','nSamp','nSlot','fSync','df','mSub', ...
               'sync','gray','msgBits','freq','toneIdx','userMsg','msgMode');
fprintf('波形已保存 %s\n', matFile);

%% ---------------- 7. 可选的单独真机发射（B210 ch1）----------------
% 单台 B210 同时收发请运行 exp34_jt65_live("hello")。
% 下面这段单独发射代码用于配合另一台独立接收机。
doTransmit = false;       % <<< 只有单独发射实验时才改成 true
txFreq     = 435e6;        % 发射中心频率 (Hz)
txGain     = 20;           % 发射增益 (dB)，从小往大加
nFrames    = 3;            % 连发几帧，每帧 46.81 s
usrpRate   = 204800;       % = 61.44e6 / 300；B210 设不了 11025 Hz，必须重采样

if doTransmit
    fprintf(2,'\n*** 即将在 %.3f MHz 发射 %d 帧（每帧 46.81 s，共 %.1f s）***\n', ...
            txFreq/1e6, nFrames, nFrames*46.81);
    fprintf(2,'*** 请确认 ch1 接的是发射天线，且接收端已在录制。***\n\n');

    % 自动识别在线的 B210（347380A 或 3237C62 都可以）
    ri = findsdru;
    b210 = ri(strcmp({ri.Platform},'B210') & strncmp({ri.Status},'Success',7));
    if isempty(b210)
        error('没有检测到在线的 B210。请检查 USB3 连接，并先关闭其他占用 USRP 的 MATLAB/GNU Radio 进程。');
    end
    serialNum = b210(1).SerialNum;
    fprintf('检测到 B210：%s\n', serialNum);

    % B210 的前端采样率必须是 MasterClockRate/InterpolationFactor。
    % 11025 Hz 不能直接配置到 B210，因此先精确重采样到 204800 Hz。
    txWave = resample(wave, 8192, 441);      % 11025 -> 204800，比例 8192/441
    txWave = single(txWave);
    txWave = 0.5 * txWave / max(max(abs(txWave)), eps('single'));
    tx = comm.SDRuTransmitter('Platform','B210','SerialNum',serialNum, ...
        'CenterFrequency',txFreq,'Gain',txGain, ...
        'MasterClockRate',61.44e6,'InterpolationFactor',300, ...
        'ChannelMapping',1,'UnderrunOutputPort',true);

    % 每次调用使用相同长度。原代码最后一次调用长度不足 1 s，
    % 某些 Support Package 版本会因此报尺寸错误或产生欠载。
    chunk = 40960;                           % 0.2 s @ 204800 Hz
    txStream = repmat(txWave,nFrames,1);
    nPad = mod(-numel(txStream),chunk);
    if nPad > 0, txStream(end+1:end+nPad) = 0; end
    fprintf('发送缓冲：%d 点，幅度峰值 %.3f，预计 %.2f s\n', ...
            numel(txStream), max(abs(txStream)), numel(txStream)/usrpRate);
    t0 = tic;
    nUnderrun = 0;
    for p = 1:chunk:numel(txStream)
        q = p + chunk - 1;
        underrun = step(tx,txStream(p:q));
        nUnderrun = nUnderrun + double(underrun);
        if mod(q/chunk, max(1,round(usrpRate/chunk*10))) == 0
            fprintf('  已发送 %.1f s\n', q/usrpRate);
        end
    end
    release(tx);
    fprintf('发射结束，共 %.1f s，耗时 %.1f s，underrun=%d\n', ...
            numel(txStream)/usrpRate, toc(t0), nUnderrun);
else
    fprintf('\n[单独发射已关闭] 一键真机收发和解码请运行 exp34_jt65_live("hello")。\n');
end
