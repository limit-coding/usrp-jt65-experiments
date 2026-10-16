% 快速检查采集文件里有没有 JT65 信号
C = load(fullfile('data','jt65_one_b210_rx.mat'));
rx = double(C.rx(:)); fs = C.fsRx;
fprintf('采集 %.2f s @ %d Hz，rxGain=%d dB，mode=%s\n', numel(rx)/fs, fs, C.rxGain, C.captureMode);

% 低通 + 2 倍降采样（与 exp4 一致）
rxd = decimate(real(rx),2,'fir') + 1i*decimate(imag(rx),2,'fir');
rxd = [rxd; zeros(2048,1)];

% 时间同步（exp4 的 syncScore）
S = load(fullfile('data','jt65_wave.mat'));
syncPos = find(S.sync==1); L = 2048;
tauMax = numel(rxd) - 126*L;
best=-inf; tauHat=0;
for tau = 0:256:tauMax
    sc = syncScore(rxd,tau,syncPos,L);
    if sc>best, best=sc; tauHat=tau; end
end
for tau = max(0,tauHat-256):min(tauMax,tauHat+256)
    sc = syncScore(rxd,tau,syncPos,L);
    if sc>best, best=sc; tauHat=tau; end
end
fprintf('时间同步：偏移 %d 点 (%.4f s)，相关值 %.3f（门限 0.5）\n', tauHat, tauHat/(fs/2), best);

% 帧内 FFT 峰
frame = rxd(tauHat+(1:126*L));
Nf = numel(frame);
X = abs(fftshift(fft(frame.*hann(Nf),Nf)));
[~,pos] = max(X);
fre = (pos-Nf/2)/Nf*fs/2;
fprintf('帧内频谱峰值：%.2f Hz（同步音应为 1270.5 Hz），频偏 %+.2f Hz\n', fre, fre-1270.5);

% 信号功率 vs 全段平均功率（帧内应明显更高）
pFrame = mean(abs(frame).^2);
pAll   = mean(abs(rxd).^2);
fprintf('帧内平均功率 %.2e vs 全段平均 %.2e（比值 %.1f dB）\n', pFrame, pAll, 10*log10(pFrame/pAll));

function s = syncScore(rxd, tau, syncPos, L)
idx = tau + (syncPos(:).'-1)*L + 1;
W   = rxd(idx + (0:L-1).');
G   = sum(conj(W(:,1:end-1)).*W(:,2:end), 1);
E   = abs(G)./sum(abs(W(:,1:end-1)).^2, 1);
s   = mean(E);
end
