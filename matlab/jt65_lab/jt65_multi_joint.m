function R = jt65_multi_joint(frameDirs,varargin)
%JT65_MULTI_JOINT 多帧联合解码：同步 → 解调 → 按载荷分组累加 → 译码。
%   R = jt65_multi_joint(frameDirs)
%   R = jt65_multi_joint(frameDirs,'SyncMode',"perframe")
%   R = jt65_multi_joint(frameDirs,'DecoderMode',"hard")
%
%   frameDirs  每帧目录，目录内需有 rx_capture.mat 与 tx_reference.mat。
%
%   两条正交的设计选择：
%   1) 同步：SyncMode="joint" 把同步得分跨**全部**帧累加后取共享 (tau,cfo)。
%      同步图案与载荷无关，所以跨不同载荷的帧累加同步得分是合法的，同步增益最大。
%      SyncMode="perframe" 复刻 exp34_jt65_average 的逐帧独立同步行为。
%   2) 累加：能量矩阵只能对**同载荷**的帧累加。本函数按每帧的 7 位载荷自动分组，
%      组内累加后各自译码。hello 按字符循环（h/e/l/l/o），所以 6 帧里每个字符
%      最多摊到 2 帧；7 位二进制载荷则每帧同载荷，全部帧进同一组。
%
%   判据只用接收能量与公开同步时隙背景；发送参考仅在判决后统计错误。
%   jt65_decode7 的拒判门限按单帧噪声模型定，跨帧累加后噪声统计改变，
%   因此同时返回 logEvidence / logOdds 原始量，供报告说明门限未重标。
p = inputParser;
addParameter(p,'SyncMode',"joint",@(v) any(v==["joint","perframe"]));
addParameter(p,'DetectionMode',"noncoherent",@(v) any(v==["noncoherent","coherent"]));
addParameter(p,'DecoderMode',"joint7",@(v) any(v==["joint7","hard"]));
parse(p,varargin{:});
o = p.Results;

frameDirs = string(frameDirs);
n = numel(frameDirs);
assert(n>=1,'没有帧目录。');

S = load(fullfile(frameDirs(1),'tx_reference.mat'));
fs = S.fs/2;          % 与 exp34_jt65_live.decodeFrame 一致：先降采样 2 倍
L = S.nSamp/2;

% ---- 读入各帧，并确定每帧的 7 位载荷（用于分组）----
xs = cell(n,1);
keys = cell(n,1);
payloads = zeros(7,n);
expectedMsg = cell(n,1);
for k = 1:n
    C = load(fullfile(frameDirs(k),'rx_capture.mat'));
    rx = double(C.rx(:));
    xs{k} = decimate(real(rx),2,'fir') + 1i*decimate(imag(rx),2,'fir');
    Sk = load(fullfile(frameDirs(k),'tx_reference.mat'));
    if isfield(Sk,'payloadIndices'), pi_ = Sk.payloadIndices; else, pi_ = (1:numel(Sk.msgBits)).'; end
    if numel(pi_) == 7
        bits = Sk.msgBits(pi_);
        keys{k} = sprintf('%d',bits);
    else
        bits = zeros(7,1); keys{k} = sprintf('x%d',k);   % 非 7 位格式：不可分组，单独成组
    end
    payloads(:,k) = bits;
    if isfield(Sk,'userMsg'), expectedMsg{k} = char(Sk.userMsg); else, expectedMsg{k} = ''; end
end

% ---- 同步：joint 跨全部帧；perframe 逐帧 ----
taus = zeros(1,n); cfos = zeros(1,n); syncScores = zeros(1,n);
if o.SyncMode == "joint"
    [tauS,cfoS,D] = jt65_sync_multi(xs,S,fs,L);
    taus(:) = tauS; cfos(:) = cfoS; syncScores(:) = D.syncScore;
else
    for k = 1:n
        [taus(k),cfos(k),Dk] = jt65_sync_multi(xs(k),S,fs,L);
        syncScores(k) = Dk.syncScore;
    end
end

% ---- 逐帧解调（每帧只做一次），缓存能量与背景 ----
Es = cell(n,1); Bs = cell(n,1);
for k = 1:n
    x = xs{k}.*exp(-2i*pi*cfos(k)*(0:numel(xs{k})-1).'/fs);
    [mlE,~,~] = jt65_demod_frame(x,taus(k),S,fs,L,o.DetectionMode);
    Es{k} = mlE;
    Bs{k} = frameBackground(x,taus(k),S,fs,L);
end

% ---- 按载荷分组，组内累加后译码 ----
[ukeys,~,gid] = unique(keys,'stable');
groups = repmat(struct('key',"",'frameIndices',[],'frameCount',0, ...
    'accepted',false,'message',"",'bitErrors',NaN,'logEvidence',NaN, ...
    'logOdds',NaN,'reason',""), 0, 1);
for g = 1:numel(ukeys)
    % 注意 reshape 成行：find 对列向量给出列，而 for k = <列向量> 只迭代一次
    % 且 k 是整个列，会让 Es{k} 展开成逗号列表。
    sel = reshape(find(gid==g),1,[]);
    accE = zeros(64,63); accB = [];
    for k = sel
        accE = accE + Es{k};
        if isempty(accB), accB = Bs{k}; else, accB = accB + Bs{k}; end
    end
    bgPower = mean(accB,2);
    if o.DecoderMode=="joint7" && numel(S.payloadIndices)==7
        [decoded,accepted,d7] = jt65_decode7(accE,bgPower);
        message = bitsToMessage(decoded,S);
        logE = d7.logEvidence; logO = d7.logOdds; reason = string(d7.reason);
        bitErr = NaN; if accepted, bitErr = nnz(decoded(S.payloadIndices) ~= payloads(:,sel(1))); end
    else
        [decoded,corrected,~] = decodeHard(accE);
        accepted = corrected>=0;
        message = bitsToMessage(decoded,S);
        logE = NaN; logO = NaN; reason = "hard";
        bitErr = NaN; if accepted, bitErr = nnz(decoded(S.payloadIndices) ~= payloads(:,sel(1))); end
    end
    groups(end+1) = struct('key',string(ukeys{g}),'frameIndices',sel, ...
        'frameCount',numel(sel),'accepted',accepted,'message',message, ...
        'bitErrors',bitErr,'logEvidence',logE,'logOdds',logO,'reason',reason); %#ok<AGROW>
end

R = struct('frameCount',n,'syncMode',char(o.SyncMode), ...
    'detectionMode',char(o.DetectionMode),'decoderMode',char(o.DecoderMode), ...
    'groups',groups,'maxGroupFrames',max([groups.frameCount]), ...
    'frameStartSeconds',taus/fs,'frequencyOffset',cfos,'syncScore',syncScores, ...
    'expectedMessages',{expectedMsg});
end

function m = bitsToMessage(decoded,S)
% 与 exp34_jt65_live / exp34_jt65_average 的消息还原一致：
% ascii7 模式还原成字符，bits7 模式保留 7 位比特串。
if isfield(S,'msgMode') && strcmp(S.msgMode,'ascii7')
    m = string(char(bi2de(decoded(S.payloadIndices).','left-msb')));
else
    m = string(char(decoded(S.payloadIndices).'+double('0')));
end
end

function [decoded,corrected,rsInfo] = decodeHard(accE)
% 与 exp34_jt65_average.decodeAccumulated 的判决尾部等价。
sym = zeros(63,1);
for j = 1:63
    [~,idx] = max(accE(:,j));
    sym(j) = idx-1;
end
back = sym; shift = bitshift(back,-1);
while any(shift), back = bitxor(back,shift); shift = bitshift(shift,-1); end
deinter = reshape(back,7,9).'; deinter = deinter(:);
bits = reshape(de2bi(deinter,6,'left-msb').',[],1);
[decoded,corrected,rsInfo] = jt65_rs_decode(bits,accE,"hard");
end

function bg = frameBackground(x,tau,S,fs,L)
% 公开同步时隙的同频背景能量，64×numel(syncPos)。与 exp34_jt65_live 一致。
tones = S.fSync + S.df*((0:63)+2);
refs = exp(2i*pi*(0:L-1).'/fs*tones);
syncPos = find(S.sync==1);
bg = zeros(64,numel(syncPos));
for j = 1:numel(syncPos)
    w = x(tau+(syncPos(j)-1)*L+(1:L));
    bg(:,j) = abs(refs'*w).^2;
end
end
