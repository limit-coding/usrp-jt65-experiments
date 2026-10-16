% test_tx：把 exp3 生成的 JT65 基带波形经 B210 ch1 真机发射
%
% 用法：
%   1) 先跑 exp3_jt65_tx_waveform.m 生成 data/jt65_wave.mat（真机发射段可关）
%   2) 另一个 MATLAB 窗口先跑 test_rx.m 开始录制，再跑本脚本
%   3) 录制时长必须覆盖发射总时长（nFrames x 46.81 s）
%
% B210 设不了 11025 Hz 前端采样率，所以先精确重采样到 204800 Hz
% （= 61.44e6 / 300，比例 8192/441），再发射。
clear; clc;

%% ---------------- 参数 ----------------
outDir    = fullfile(fileparts(mfilename('fullpath')),'..','..','data');
matFile   = fullfile(outDir,'jt65_wave.mat');
txFreq    = 435e6;        % 发射中心频率 (Hz)，要和 test_rx 的 rxFreq 一致
txGain    = 20;           % 发射增益 (dB)，从小往大加
nFrames   = 3;            % 连发几帧，每帧 46.81 s
usrpRate  = 204800;       % = 61.44e6 / 300

assert(exist(matFile,'file')==2, '找不到 %s，请先运行 exp3_jt65_tx_waveform.m', matFile);
S = load(matFile);

%% ---------------- 重采样 + 归一化 ----------------
txWave = resample(S.wave, 8192, 441);     % 11025 -> 204800 Hz
txWave = single(txWave);
txWave = 0.5 * txWave / max(max(abs(txWave)), eps('single'));

%% ---------------- 连接 B210（自动识别在线的设备）----------------
ri = findsdru;
b210 = ri(strcmp({ri.Platform},'B210') & strncmp({ri.Status},'Success',7));
assert(~isempty(b210), '没有检测到在线的 B210。请检查 USB3 连接，并先关闭其他占用 USRP 的 MATLAB/GNU Radio 进程。');
serialNum = b210(1).SerialNum;
fprintf('检测到 B210：%s\n', serialNum);

tx = comm.SDRuTransmitter('Platform','B210','SerialNum',serialNum, ...
    'CenterFrequency',txFreq,'Gain',txGain, ...
    'MasterClockRate',61.44e6,'InterpolationFactor',300, ...
    'ChannelMapping',1,'UnderrunOutputPort',true);

%% ---------------- 发射 ----------------
% 每次 step 的长度必须一致，否则部分 Support Package 版本会报尺寸错误或欠载，
% 所以先把整段流补零对齐到 chunk 的整数倍，再按固定长度循环发送。
fprintf(2,'*** 即将在 %.3f MHz 发射 %d 帧（每帧 46.81 s，共 %.1f s）***\n', ...
        txFreq/1e6, nFrames, nFrames*46.81);
fprintf(2,'*** 请确认 ch1 接的是发射天线，且 test_rx 已在录制。***\n\n');

chunk = 40960;                            % 0.2 s @ 204800 Hz
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
