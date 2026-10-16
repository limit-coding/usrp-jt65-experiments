function report = exp34_jt65_average(sourceDir, opts)
%EXP34_JT65_AVERAGE 多帧平均：同载荷重复帧对齐后非相干累加，用观测时间换灵敏度。
%   report = exp34_jt65_average("某次 data/jt65_loop_时间 的完整路径")
%
% 思路：逐帧独立做时/频同步与解调，得到每帧的 64x63 能量矩阵 mlEnergy；把同一
% 载荷的各帧矩阵相加，再统一解调译码。非相干累加让信噪比按 10*log10(N) 提升
% （2 帧 +3 dB，4 帧 +6 dB，16 帧 +12 dB）。
%
% 关键前提：参与累加的帧必须发送相同载荷。二进制 7 bit 模式每帧都重复，用
% GroupModulo=1；ASCII 文字模式按字符循环，用 GroupModulo=字符数（默认按
% tx_reference.mat 里的 sequenceLength 自动判定）。
%
% 这是"用观测时间换灵敏度"，不是单帧灵敏度：报告里每组的等效提升单独列出，不应
% 与单帧门限混为一谈。发送参考只在译码完成后用于误差统计，不参与累加或判决。
arguments
    sourceDir (1,1) string
    opts.Frames (1,:) double = []                    % 参与平均的帧号；默认全部
    opts.GroupModulo (1,1) double {mustBeNonnegative} = 0   % 0 = 自动判定
    opts.DetectionMode (1,1) string {mustBeMember(opts.DetectionMode,["noncoherent","coherent"])} = "noncoherent"
    opts.DecoderMode (1,1) string {mustBeMember(opts.DecoderMode,["hard","erasure"])} = "hard"
    opts.ShowPlots (1,1) logical = false
    opts.KeepAnalysis (1,1) logical = false           % 是否保留逐帧 analysis_* 目录
end
frameDirs = discoverFrames(sourceDir);
n = numel(frameDirs);
assert(n>=1,'没有找到可用的帧目录。');
if ~isempty(opts.Frames)
    idx = opts.Frames(opts.Frames>=1 & opts.Frames<=n);
    assert(~isempty(idx),'Frames 超出范围。');
    frameDirs = frameDirs(idx);
    n = numel(frameDirs);
end
fprintf('多帧平均：%d 帧，解调 %s，译码 %s\n',n,opts.DetectionMode,opts.DecoderMode);

S = load(fullfile(frameDirs{1},'tx_reference.mat'));
groupMod = opts.GroupModulo;
if groupMod==0
    if isfield(S,'sequenceLength'), groupMod = S.sequenceLength; else, groupMod = 1; end
end
groupMod = max(1,round(groupMod));
fprintf('载荷分组：period = %d 帧%s\n',groupMod, ...
    ternary(groupMod==1,'（每帧同载荷）','（按字符循环）'));

energies = cell(1,n); groups = zeros(1,n); starts = nan(1,n); cfo = nan(1,n);
perFrame = struct('frame',{},'group',{},'frameStartSeconds',{},'frequencyOffset',{}, ...
    'syncScore',{},'symbolErrors',{},'accepted',{},'message',{});
for k = 1:n
    R = exp34_jt65_live(ReplayDirectory=frameDirs{k},ShowPlots=false, ...
        DetectionMode=opts.DetectionMode,DecoderMode="hard");
    energies{k} = R.diagnostics.mlEnergy;
    groups(k) = mod(k-1,groupMod)+1;
    starts(k) = R.frameStartSeconds; cfo(k) = R.frequencyOffset;
    perFrame(k) = struct('frame',k,'group',groups(k), ...
        'frameStartSeconds',R.frameStartSeconds,'frequencyOffset',R.frequencyOffset, ...
        'syncScore',R.syncScore,'symbolErrors',R.symbolErrors, ...
        'accepted',R.decoderAccepted,'message',R.message);
    if ~opts.KeepAnalysis, cleanupAnalysis(frameDirs{k}); end
    fprintf('  帧 %2d：组 %d，同步得分 %.3f，单帧符号错误 %2d/63，单帧%s\n', ...
        k,groups(k),R.syncScore,R.symbolErrors,ternary(R.decoderAccepted,'解出','未解出'));
end

results = struct('group',{},'frames',{},'message',{},'symbolErrors',{}, ...
    'accepted',{},'correctedSymbols',{},'rsMode',{},'equivalentGainDb',{});
for g = 1:groupMod
    sel = find(groups==g);
    if isempty(sel), continue; end
    acc = zeros(size(energies{1}));
    for k = sel, acc = acc+energies{k}; end
    % 每组用本组第一帧的发送参考做误差统计（ASCII 模式下各组发送字符不同）
    Sg = load(fullfile(frameDirs{sel(1)},'tx_reference.mat'));
    [message,symErr,accepted,corrected,rsMode] = decodeAccumulated(acc,Sg,opts.DecoderMode);
    gainDb = 10*log10(numel(sel));
    results(end+1) = struct('group',g,'frames',numel(sel),'message',message, ...
        'symbolErrors',symErr,'accepted',accepted,'correctedSymbols',corrected, ...
        'rsMode',rsMode,'equivalentGainDb',gainDb); %#ok<AGROW>
    fprintf('组 %d（发送 "%s"，%d 帧平均，等效 +%.2f dB）→ 符号错误 %2d/63，%s，消息 "%s"\n', ...
        g,Sg.userMsg,numel(sel),gainDb,symErr,ternary(accepted,'解出','未解出'),message);
end

report = struct('sourceDirectory',char(sourceDir),'frameCount',n, ...
    'groupModulo',groupMod,'detectionMode',char(opts.DetectionMode), ...
    'decoderMode',char(opts.DecoderMode),'perFrame',perFrame,'groups',results);
if opts.ShowPlots
    plotAverage(energies,groups,S);
end
end

function [message,symErr,accepted,corrected,rsMode] = decodeAccumulated(mlEnergy,S,decoderMode)
% 与 exp34_jt65_live 的解码尾部等价：能量矩阵 -> 判决 -> 逆格雷 -> 解交织 -> RS。
sym = zeros(63,1);
for j = 1:63
    [~,idx] = max(mlEnergy(:,j));
    sym(j) = idx-1;
end
back = sym; shift = bitshift(back,-1);
while any(shift), back = bitxor(back,shift); shift = bitshift(shift,-1); end
deinter = reshape(back,7,9).'; deinter = deinter(:);
bits = reshape(de2bi(deinter,6,'left-msb').',[],1);
[decoded,corrected,rsInfo] = jt65_rs_decode(bits,mlEnergy,decoderMode);
accepted = corrected>=0;
rsMode = rsInfo.mode;
if isfield(S,'payloadIndices'), payloadIndices = S.payloadIndices; else, payloadIndices = (1:numel(S.msgBits)).'; end
message = char(bi2de(reshape(decoded,8,[]).','left-msb')).';
if isfield(S,'msgMode') && strcmp(S.msgMode,'bits7')
    message = char(decoded(payloadIndices).'+double('0'));
end
if isfield(S,'msgMode') && strcmp(S.msgMode,'ascii7')
    message = char(bi2de(decoded(payloadIndices).','left-msb'));
end
symErr = nnz(sym~=S.gray);
if ~accepted, message = '[未恢复]'; end
end

function dirs = discoverFrames(sourceDir)
% 整组目录（含 frame_* 子目录）或单个帧目录都支持。
sourceDir = char(sourceDir);
sub = dir(fullfile(sourceDir,'frame_*'));
dirs = {};
for k = 1:numel(sub)
    if sub(k).isdir && isfile(fullfile(sourceDir,sub(k).name,'rx_capture.mat'))
        dirs{end+1} = fullfile(sourceDir,sub(k).name); %#ok<AGROW>
    end
end
if isempty(dirs) && isfile(fullfile(sourceDir,'rx_capture.mat'))
    dirs = {sourceDir};
end
end

function cleanupAnalysis(frameDir)
d = dir(fullfile(frameDir,'analysis_*'));
for k = 1:numel(d)
    if d(k).isdir, rmdir(fullfile(frameDir,d(k).name),'s'); end
end
end

function s = ternary(cond,a,b)
if cond, s = a; else, s = b; end
end

function plotAverage(energies,groups,S)
figure('Color','w','Position',[60 60 1200 700]);
g = unique(groups);
for k = 1:numel(g)
    acc = zeros(size(energies{1}));
    for j = find(groups==g(k)), acc = acc+energies{j}; end
    subplot(numel(g),1,k);
    imagesc((0:62),0:63,10*log10(acc/max(acc(:))+eps)); axis xy;
    hold on; plot(0:62,S.gray+0.5,'r.','MarkerSize',4);
    ylabel(sprintf('组%d\\newline %d帧',g(k),nnz(groups==g(k))));
    if k==1, title('平均后的 64x63 能量（dB，红点为发送符号）'); end
    if k==numel(g), xlabel('符号序号'); end
    colorbar;
end
end
