function [mlEnergy,sym,D] = jt65_demod_frame(x,tau,S,fs,L,mode)
%JT65_DEMOD_FRAME 一帧的 64 音最大似然解调（非相干 / 相干两种）。
%   [mlEnergy,sym,D] = jt65_demod_frame(x,tau,S,fs,L,"noncoherent")
%
% mode="noncoherent"（默认，与原实现完全一致）
%   逐符号比较 64 个候选音的相关能量 |refs'*w|^2，取最大。
%
% mode="coherent"（新增）
%   JT65 是相位连续 FSK，且音调间隔 df 与符号时长 T 满足 df*T ≈ 1，因此各符号
%   的起始相位除公共复参考 a 外基本确定：
%       phase_k = phase_0 + (k-1)*2*pi*fSync*T
%   但同步搜索的时间网格较粗（本实现为 16 个抽样），残留的定时偏差 tau_off 会让
%   每个符号再叠加一个与频率成正比的相位 2*pi*f_k*tau_off。实测该残差可达 1% 个
%   符号，不加这一项时相干度只有 0.46，加上后回到 0.998。因此这里把
%       phase_k = phase_0 + (k-1)*delta + 2*pi*(f_k - fSync)*psi,  psi = 2*pi*tau_off
%   一起建模。psi 用非相干判决当导频来估计（不依赖发送参考）。
%   （曾试过"各符号相干度量最大值之和"作盲搜索准则：低信噪比下会被噪声带偏，
%     -20 dB 处锁到错误 psi，符号错误升到 38/63；导频法没有这个问题。）
%
%   判决用实数相干度量；mlEnergy 仍返回非相干能量，供译码器评估可靠度，语义不变。
%
% 本函数只做解调，不做同步、不译码、不使用发送参考。
arguments
    x (:,1) double
    tau (1,1) double
    S struct
    fs (1,1) double
    L (1,1) double
    mode (1,1) string {mustBeMember(mode,["noncoherent","coherent"])} = "noncoherent"
end
tones = S.fSync+S.df*((0:63)+2);
refs = exp(2i*pi*(0:L-1).'/fs*tones);
dataPos = find(S.sync==0);
sym = zeros(63,1); mlEnergy = zeros(64,63);
D = struct('detectionMode',char(mode),'phaseReference',[],'phaseCoherence',NaN, ...
    'phaseDriftRad',NaN,'timingOffsetRadPerHz',NaN,'timingOffsetSeconds',NaN, ...
    'timingOffsetSamples',NaN);
if mode=="noncoherent"
    for j = 1:63
        w = x(tau+(dataPos(j)-1)*L+(1:L));
        mlEnergy(:,j) = abs(refs'*w).^2;
        [~,idx] = max(mlEnergy(:,j));
        sym(j) = idx-1;
    end
    return;
end
% ---------------- 相干检测 ----------------
T = L/fs;
delta = 2*pi*S.fSync*T;
syncPos = find(S.sync==1);
refSync = exp(2i*pi*(0:L-1).'/fs*S.fSync);
residual = zeros(numel(syncPos),1);
for j = 1:numel(syncPos)
    w = x(tau+(syncPos(j)-1)*L+(1:L));
    residual(j) = (refSync'*w)*exp(-1i*(syncPos(j)-1)*delta);
end
a = mean(residual);
unitResidual = residual./max(abs(residual),realmin);
D.phaseReference = a;
D.phaseCoherence = abs(mean(unitResidual));
% 漂移取"去掉平均相位后"的残余展布；直接对 angle 取极差会在相位绕 ±π 时虚高。
centered = unitResidual*exp(-1i*angle(mean(unitResidual)));
D.phaseDriftRad = max(angle(centered))-min(angle(centered));
% 所有数据符号的相关矩阵（一次算完，供 psi 搜索复用）
W = zeros(L,63);
for j = 1:63, W(:,j) = x(tau+(dataPos(j)-1)*L+(1:L)); end
C = refs'*W;
mlEnergy = abs(C).^2;
kPhase = (dataPos-1).'*delta;          % 1x63
% 用非相干判决当导频估计 psi = 2*pi*tau_off。
% 不能用"各符号相干度量最大值之和"作准则：低信噪比下该准则会被噪声带偏，实测
% 会在 -20 dB 处锁到错误的 psi，符号错误反而升到 38/63。导频法稳健得多。
[~,ncIdx] = max(mlEnergy,[],1);
lin = sub2ind(size(C),ncIdx,1:63);
pilot = C(lin)./max(abs(C(lin)),realmin);
pilot = pilot.*exp(-1i*kPhase);        % 去掉模型相位，只剩 2*pi*(f-fSync)*psi
fPilot = tones(ncIdx)-S.fSync;         % 1x63
psiGrid = linspace(-0.20,0.20,2001);   % rad/Hz，对应 tau_off ±32 ms（符号长度的 8.6%）
% 范围要够宽：低信噪比下同步落点会偏几十个抽样，实测偏差可达 11.6 ms；范围不够
% 时 psi 会被截断在边界，相位模型整体错掉，符号错误接近随机。
% 步长 0.0002 rad/Hz 在 172 Hz 音调跨度上只留 0.034 rad 残余相位。
bestV = -Inf; bestPsi = 0;
for psi = psiGrid
    v = abs(sum(pilot.*exp(-1i*fPilot*psi)));
    if v>bestV, bestV = v; bestPsi = psi; end
end
ph = a*exp(1i*(kPhase+(tones-S.fSync).'*bestPsi));   % 64x63
bestM = real(conj(ph).*C);
[~,idx] = max(bestM,[],1);
sym = (idx-1).';
D.phaseCoherence = bestV/63;
D.timingOffsetRadPerHz = bestPsi;
D.timingOffsetSeconds = bestPsi/(2*pi);
D.timingOffsetSamples = bestPsi/(2*pi)*fs;
D.coherentMetric = bestM;
% 把非相干判决一并带回，供译码失败时回退。psi 偶尔会锁到错误位置（实测 -20 dB 有
% 约 1/6 的帧符号错误反而变大），回退保证相干路径"只增不减"。
D.alternateSymbols = (ncIdx-1).';
end
