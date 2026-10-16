% test_rx：B210 ch2 真机采集 JT65 信号，存成 exp4 可直接读取的文件
%
% 用法：
%   1) 先跑本脚本开始录制（recSeconds >= 一帧 46.81 s）
%   2) 尽快在另一个 MATLAB 窗口跑 test_tx.m 发射
%   3) 录完后在 exp4_jt65_rx_demod.m 里把 captureFile 改成下面的 rawFile 即可解调
%
% B210 设不了 11025 Hz，所以按 204800 Hz 采集，再精确重采样到 11025 Hz
% （204800/11025 = 8192/441），和 exp4 的 fs 对齐。
clear; clc;

%% ---------------- 参数 ----------------
outDir    = fullfile(fileparts(mfilename('fullpath')),'..','..','data');
rawFile   = fullfile(outDir,'jt65_rx_raw.mat');
rxFreq    = 435e6;        % 接收中心频率 (Hz)，要和 test_tx 的 txFreq 一致
rxGain    = 20;           % 接收增益 (dB)，两副天线离得近，从小往大调
recSeconds= 60;           % 采集时长 (s)，必须 >= 一帧 46.81 s
usrpRate  = 204800;       % = 61.44e6 / 300
fs        = 11025;        % 重采样后的采样率，和 exp4 一致

if ~exist(outDir,'dir'), mkdir(outDir); end

%% ---------------- 连接 B210（自动识别在线的设备）----------------
ri = findsdru;
b210 = ri(strcmp({ri.Platform},'B210') & strncmp({ri.Status},'Success',7));
assert(~isempty(b210), '没有检测到在线的 B210。请检查 USB3 连接，并先关闭其他占用 USRP 的 MATLAB/GNU Radio 进程。');
serialNum = b210(1).SerialNum;
fprintf('检测到 B210：%s\n', serialNum);

rxObj = comm.SDRuReceiver('Platform','B210','SerialNum',serialNum, ...
    'CenterFrequency',rxFreq,'Gain',rxGain, ...
    'MasterClockRate',61.44e6,'DecimationFactor',300, ...
    'SamplesPerFrame',usrpRate/10,'OutputDataType','double', ...
    'ChannelMapping',2);                        % ch2 接收，ch1 留给发射

%% ---------------- 采集 ----------------
n = ceil(recSeconds*usrpRate);
buf = complex(zeros(n,1));
p = 0; nOver = 0; nextMark = 10;
fprintf('开始采集 %.1f s（ch2）...\n', recSeconds);
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
        fprintf('  %.0f / %.0f s\n', p/usrpRate, recSeconds);
        nextMark = nextMark + 10;
    end
end
release(rxObj);
fprintf('采集完成：%.1f s，缓冲溢出 %d 次\n', toc(t0), nOver);

%% ---------------- 重采样到 11025 Hz 并存盘 ----------------
rx = resample(buf, 441, 8192);                  % 204800 -> 11025 Hz
fsRx = fs;
save(rawFile,'rx','fsRx','rxFreq','rxGain','recSeconds');
fprintf('IQ 已存 %s（%d 点 @ %d Hz）\n', rawFile, numel(rx), fsRx);
fprintf('在 exp4_jt65_rx_demod.m 里把 captureFile 改成此文件即可解调。\n');

%% ---------------- 快速频谱检查 ----------------
[~, fAx, tAx, P] = spectrogram(rx, 2048, 1920, 4096, fs);
figure('Name','test_rx 频谱','Position',[100 100 900 500]);
imagesc(tAx, fAx, 10*log10(abs(P)+eps)); axis xy;
ylim([1100 1600]); xlabel('时间 (s)'); ylabel('频率 (Hz)');
title('接收瀑布图（应能看到 1270.5 Hz 同步音及其上方的数据音）');
colorbar;
