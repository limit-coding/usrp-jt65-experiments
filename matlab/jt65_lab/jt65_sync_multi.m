function [tau,cfo,D] = jt65_sync_multi(xs,S,fs,L)
%JT65_SYNC_MULTI 多帧联合同步：同步得分在整组帧上累加后再取峰。
%   [tau,cfo,D] = jt65_sync_multi(xs,S,fs,L)
%
%   xs  是 cell，每个元素是一帧已经降到分析率、长度相同的接收信号。
%   传单元素时可退化为单帧同步（与 exp34_jt65_live 的 jointSynchronize 同算法）。
%
%   为什么能跨帧相加：得分函数 syncEnergyScores 返回归一化值
%   (Es-Ed)/(Es+Ed) ∈ [-1,1]，逐帧等权，因此直接累加就是合法的非相干积分，
%   不需要按各帧功率配平。这是本函数相对单帧同步唯一实质的区别。
%
%   动机：exp34_jt65_average 是先逐帧独立同步、再把 mlEnergy 累加。低信噪比下
%   单帧同步峰会落到错误位置，那一帧的能量是垃圾，累加时把正确能量淹掉，
%   于是出现"−30 dB 下 8 帧平均也是 0"。把同步本身也做成跨帧累加，
%   同步就同样吃到 10*log10(N) 的增益。
%
%   本函数只做同步，不解调、不译码、不使用发送参考。
arguments
    xs (:,1) cell
    S struct
    fs (1,1) double
    L (1,1) double
end
factor = 16;
fsSync = fs/factor;
ls = L/factor;
n = numel(xs);

ys = cell(n,1);
tauMax = inf;
for k = 1:n
    x = xs{k}(:);
    ys{k} = decimate(x.*exp(-2i*pi*S.fSync*(0:numel(x)-1).'/fs),factor,'fir');
    tauMax = min(tauMax, min(numel(ys{k})-S.nSlot*ls, ...
        floor((numel(x)-S.nSlot*L)/factor)));
end
tauMax = floor(tauMax);
assert(tauMax >= 0,'接收数据不足一帧，无法同步。');

% 粗联合搜索：时间网格（ls/16）× 频偏网格（±20 Hz, 0.5 Hz）
offsets = -20:0.5:20;
starts = (0:ls/16:tauMax).';
map = zeros(numel(starts),numel(offsets));
for j = 1:numel(offsets)
    map(:,j) = scoreMulti(ys,offsets(j),fsSync,ls,starts,S.sync);
end
[~,peak] = max(map(:));
[p,q] = ind2sub(size(map),peak);
tau = round(starts(p)*factor);

% 频偏精化
if S.df > 20
    % 加速版首个数据音距同步音约 100 Hz，±20 Hz 内只有同步音。
    cfo = refineMulti(xs,tau,S,fs,L,0,20);
else
    cfo = refineMulti(xs,tau,S,fs,L,offsets(q),0.75);
end
cfo = max(-20,min(20,round(cfo*100)/100));

% 时间/频偏两轮互精化（与单帧算法同结构，只是每次得分都是跨帧累加的）
allStarts = (0:tauMax).';
for iter = 1:2
    sc = scoreMulti(ys,cfo,fsSync,ls,allStarts,S.sync);
    [~,p] = max(sc);
    tau = round(allStarts(p)*factor);
    cfo = refineMulti(xs,tau,S,fs,L,cfo,0.15);
    cfo = max(-20,min(20,round(cfo*100)/100));
end
sc = scoreMulti(ys,cfo,fsSync,ls,allStarts,S.sync);
[~,p] = max(sc);
tau = round(allStarts(p)*factor);

D = struct('method','multi-frame joint energy','frameCount',n, ...
    'syncScore',sc(p),'tau',tau,'frequencyOffset',cfo, ...
    'searchFrequencyOffsetsHz',offsets,'searchScoreMap',map);
end

function score = scoreMulti(ys,cfo,fsSync,ls,starts,sync)
% 归一化得分跨帧等权累加 —— 联合同步的全部要点就在这一行。
score = zeros(numel(starts),1);
for k = 1:numel(ys)
    score = score + syncEnergyScores(ys{k},cfo,fsSync,ls,starts,sync);
end
end

function score = syncEnergyScores(y,cfo,fs,L,starts,sync)
% 与 exp34_jt65_live 中的同名局部函数逐字等价，此处重新实现以便跨帧复用。
mix = y.*exp(-2i*pi*cfo*(0:numel(y)-1).'/fs);
cs = [0;cumsum(mix)];
energy = abs(cs(L+1:end)-cs(1:end-L)).^2;
slots = energy(starts+1+(0:numel(sync)-1)*L);
es = sum(slots(:,sync==1),2);
ed = sum(slots(:,sync==0),2);
score = (es-ed)./(es+ed+realmin);
end

function cfo = refineMulti(xs,tau,S,fs,L,center,halfWidth)
% 多帧 |频谱| 非相干累加后找峰；单元素时等价于 exp34_jt65_live.refineFrequency。
nf = S.nSlot*L;
f = (-floor(nf/2):ceil(nf/2)-1).'*fs/nf;
spec = zeros(numel(f),1);
for k = 1:numel(xs)
    x = xs{k}(:);
    spec = spec + abs(fftshift(fft(x(tau+(1:nf)).*hann(nf))));
end
search = find(abs(f-S.fSync-center) <= halfWidth);
[~,j] = max(spec(search));
cfo = f(search(j))-S.fSync;
end
