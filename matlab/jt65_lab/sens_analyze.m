function report = sens_analyze(sweepDir,varargin)
%SENS_ANALYZE 对 sens_capture 采到的一批档位做灵敏度分析，输出总表。
%   report = sens_analyze(sweepDir)
%   report = sens_analyze(sweepDir,'TxGains',[4 2 0])   % 只分析指定档位
%
%   对每一档，用**同一批原始 IQ**跑下列方法，统计"正确解出"（accepted 且 0 比特错）：
%     单帧：非相干+硬判决 / 相干+硬判决 / 非相干+joint7
%     多帧：逐帧同步+非相干平均+硬判决（现有 exp34_jt65_average 路径）
%           逐帧同步+非相干平均+joint7   （新增）
%           联合同步+非相干平均+joint7   （新增，本项目核心改动）
%
%   零软件加噪：全程只读录波，不改变任何样本。
p = inputParser;
addParameter(p,'TxGains',[]);
addParameter(p,'ShowPlots',false);
parse(p,varargin{:});
o = p.Results;

sweepDir = char(sweepDir);
T = load(fullfile(sweepDir,'index.mat'));
idx = T.index;
ok = find([idx.ok]);
if ~isempty(o.TxGains)
    ok = ok(ismember([idx(ok).txGain], o.TxGains));
end
assert(~isempty(ok),'没有匹配的成功档位。');
say('待分析档位 %d 个：TxGain = %s', numel(ok), mat2str([idx(ok).txGain]));

levels = emptyLevels();
for ii = 1:numel(ok)
    k = ok(ii);
    d = char(idx(k).directory);
    frames = discoverFrames(d);
    fprintf('\n=== TxGain %.1f dB（%d 帧）%s ===\n', idx(k).txGain, numel(frames), d);
    Lv = emptyLevel();
    Lv.txGain = idx(k).txGain;
    Lv.rxGain = idx(k).rxGain;
    Lv.frameCount = numel(frames);
    if ~isempty(frames)
        Lv = analyzeLevel(Lv, frames);
    end
    if isempty(levels), levels = Lv; else, levels(end+1) = Lv; end %#ok<AGROW>
    printLevel(Lv);
    save(fullfile(sweepDir,'results.mat'),'levels');
end

report = struct('sweepDir',sweepDir,'levels',levels,'analyzedAt',datestr(now));
save(fullfile(sweepDir,'results.mat'),'levels','report');
writeTables(sweepDir, levels);
if o.ShowPlots, plotReport(levels, sweepDir); end
say('\n分析完成：%s', sweepDir);
end

% ---------------------------------------------------------------- level
function Lv = analyzeLevel(Lv, frames)
n = numel(frames);
hard = false(1,n); coh = false(1,n); j7 = false(1,n);
snr = nan(1,n); symErr = nan(1,n);
for k = 1:n
    f = frames{k};
    Rh = runLive(f,'noncoherent','hard');
    Rc = runLive(f,'coherent','hard');
    R7 = runLive(f,'noncoherent','joint7');
    if ~isempty(Rh)
        hard(k) = Rh.passed; snr(k) = Rh.snr.referenceSnrDb(2); symErr(k) = Rh.symbolErrors;
    end
    if ~isempty(Rc), coh(k) = Rc.passed; end
    if ~isempty(R7), j7(k) = R7.passed; end
end
Lv.singleHard = [nnz(hard) n];
Lv.singleCoh  = [nnz(coh) n];
Lv.singleJ7   = [nnz(j7) n];
Lv.snrPerFrame = snr;
Lv.snrMean = mean(snr,'omitnan');
Lv.snrSpread = max(snr)-min(snr);
Lv.supplementarySymbolErrors = symErr;

% 多帧 1：现有路径（逐帧独立同步 + 硬判决）
try
    A = exp34_jt65_average(string(fileparts(frames{1})), DecoderMode="hard");
    exp = averageGroupExpected(frames);
    Lv.avgHard = countGroups({A.groups.accepted}, {A.groups.message}, exp);
catch ME
    say('  exp34_jt65_average 失败：%s', ME.message);
end

% 多帧 2：逐帧同步 + joint7
try
    Rp = jt65_multi_joint(frames,'SyncMode','perframe','DecoderMode','joint7');
    Lv.perframeJ7 = countGroups({Rp.groups.accepted}, {Rp.groups.message}, keyExpected(frames, {Rp.groups.key}));
    Lv.maxGroupFramesPerframe = Rp.maxGroupFrames;
catch ME
    say('  perframe+joint7 失败：%s', ME.message);
end

% 多帧 3：联合同步 + joint7（核心新增）
try
    Rj = jt65_multi_joint(frames,'SyncMode','joint','DecoderMode','joint7');
    Lv.jointJ7 = countGroups({Rj.groups.accepted}, {Rj.groups.message}, keyExpected(frames, {Rj.groups.key}));
    Lv.maxGroupFrames = Rj.maxGroupFrames;
    Lv.jointFrameStarts = Rj.frameStartSeconds;
    Lv.jointCfo = Rj.frequencyOffset;
    Lv.jointSyncScore = Rj.syncScore;
catch ME
    say('  joint+joint7 失败：%s', ME.message);
end

% 多帧 4（参考）：联合同步 + 硬判决
try
    Rh2 = jt65_multi_joint(frames,'SyncMode','joint','DecoderMode','hard');
    Lv.jointHard = countGroups({Rh2.groups.accepted}, {Rh2.groups.message}, keyExpected(frames, {Rh2.groups.key}));
catch ME
    say('  joint+hard 失败：%s', ME.message);
end
end

% ---------------------------------------------------------------- helpers
function R = runLive(frameDir, detectionMode, decoderMode)
% 单帧回放，走原始 exp34_jt65_live 路径，保证与既有结果可比。
try
    R = exp34_jt65_live(ReplayDirectory=string(frameDir), ShowPlots=false, ...
        SyncMode="joint", DecoderMode=decoderMode, DetectionMode=detectionMode);
catch ME
    say('    单帧失败（%s/%s）：%s', detectionMode, decoderMode, ME.message);
    R = [];
end
cleanupAnalysis(frameDir);
end

function out = countGroups(accepted, message, expected)
na = numel(accepted);
ok = false(1,na);
for k = 1:na
    if ~accepted{k}, continue; end
    if k <= numel(expected) && ~isempty(expected{k})
        ok(k) = strcmp(char(message{k}), expected{k});
    else
        ok(k) = true;   % 无参考信息时只能按 accepted 计
    end
end
out = [nnz(ok) na];
end

function exp = keyExpected(frames, keys)
% 由分组键（7 位载荷）反推该组应解出的字符/比特串。
S1 = load(fullfile(frames{1},'tx_reference.mat'));
isAscii = isfield(S1,'msgMode') && strcmp(S1.msgMode,'ascii7');
exp = cell(1,numel(keys));
for g = 1:numel(keys)
    key = char(keys{g});
    if numel(key)==7 && all(key=='0' | key=='1')
        % key 是 1x7 行向量，bi2de 按行取值 ⇒ 不要转置，否则会得到 7 个 0/1
        if isAscii
            exp{g} = char(bi2de(double(key)-double('0'),'left-msb'));
        else
            exp{g} = key;
        end
    else
        exp{g} = '';
    end
end
end

function exp = averageGroupExpected(frames)
% 复刻 exp34_jt65_average 的分组（mod(k-1, sequenceLength)+1），给出每组应解出的字符。
S1 = load(fullfile(frames{1},'tx_reference.mat'));
gm = numel(frames);
if isfield(S1,'sequenceLength'), gm = max(1,round(S1.sequenceLength)); end
exp = cell(1,gm);
for g = 1:gm
    sel = find(mod((1:numel(frames))-1, gm)+1 == g);
    if isempty(sel), continue; end
    Sg = load(fullfile(frames{sel(1)},'tx_reference.mat'));
    if isfield(Sg,'userMsg'), exp{g} = char(Sg.userMsg); end
end
end

function printLevel(Lv)
say('  SNR(2500) 均值 %6.2f dB，跨帧散布 %.1f dB（%d 帧）', ...
    Lv.snrMean, Lv.snrSpread, Lv.frameCount);
say('  单帧    硬 %d/%d | 相干 %d/%d | joint7 %d/%d', ...
    Lv.singleHard(1),Lv.singleHard(2), Lv.singleCoh(1),Lv.singleCoh(2), ...
    Lv.singleJ7(1),Lv.singleJ7(2));
say('  多帧    逐帧+硬 %d/%d | 逐帧+joint7 %d/%d | 联合+joint7 %d/%d | 联合+硬 %d/%d', ...
    Lv.avgHard(1),Lv.avgHard(2), Lv.perframeJ7(1),Lv.perframeJ7(2), ...
    Lv.jointJ7(1),Lv.jointJ7(2), Lv.jointHard(1),Lv.jointHard(2));
if ~isnan(Lv.maxGroupFrames)
    say('  最大同载荷组 %d 帧', Lv.maxGroupFrames);
end
end

function frames = discoverFrames(d)
sub = dir(fullfile(d,'frame_*'));
frames = {};
for k = 1:numel(sub)
    if sub(k).isdir && isfile(fullfile(d,sub(k).name,'rx_capture.mat'))
        frames{end+1} = fullfile(d,sub(k).name); %#ok<AGROW>
    end
end
end

function cleanupAnalysis(frameDir)
d = dir(fullfile(frameDir,'analysis_*'));
for k = 1:numel(d)
    if d(k).isdir, rmdir(fullfile(frameDir,d(k).name),'s'); end
end
end

function L = emptyLevel()
L = struct('txGain',NaN,'rxGain',NaN,'frameCount',0, ...
    'snrMean',NaN,'snrSpread',NaN,'snrPerFrame',[], ...
    'singleHard',[0 0],'singleCoh',[0 0],'singleJ7',[0 0], ...
    'avgHard',[0 0],'perframeJ7',[0 0],'jointJ7',[0 0],'jointHard',[0 0], ...
    'maxGroupFrames',NaN,'maxGroupFramesPerframe',NaN, ...
    'jointFrameStarts',[],'jointCfo',[],'jointSyncScore',[], ...
    'supplementarySymbolErrors',[]);
end

function L = emptyLevels()
L = repmat(emptyLevel(),0,1);
end

function writeTables(sweepDir, levels)
fid = fopen(fullfile(sweepDir,'sensitivity.csv'),'w');
fprintf(fid,'txGain_dB,rxGain_dB,frames,snr2500_mean_dB,snr2500_spread_dB,');
fprintf(fid,'single_hard,single_coh,single_joint7,avg_hard,perframe_joint7,joint_joint7,joint_hard\n');
for k = 1:numel(levels)
    L = levels(k);
    fprintf(fid,'%.1f,%.1f,%d,%.2f,%.2f,%d/%d,%d/%d,%d/%d,%d/%d,%d/%d,%d/%d,%d/%d\n', ...
        L.txGain,L.rxGain,L.frameCount,L.snrMean,L.snrSpread, ...
        L.singleHard(1),L.singleHard(2), L.singleCoh(1),L.singleCoh(2), ...
        L.singleJ7(1),L.singleJ7(2), L.avgHard(1),L.avgHard(2), ...
        L.perframeJ7(1),L.perframeJ7(2), L.jointJ7(1),L.jointJ7(2), ...
        L.jointHard(1),L.jointHard(2));
end
fclose(fid);

md = fopen(fullfile(sweepDir,'sensitivity.md'),'w');
fprintf(md,'# 真机灵敏度扫描（零软件加噪）\n\n');
fprintf(md,'全部为真实采集回放；信噪比只由 TxGain/RxGain 改变，未向任何样本叠加噪声。\n\n');
fprintf(md,'| TX/dB | 帧 | SNR(2500) 均值 | 散布 | 单帧硬 | 单帧相干 | 单帧joint7 | 逐帧+硬 | 逐帧+joint7 | 联合+joint7 | 联合+硬 |\n');
fprintf(md,'|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n');
for k = 1:numel(levels)
    L = levels(k);
    fprintf(md,'| %.1f | %d | %.2f | %.1f | %d/%d | %d/%d | %d/%d | %d/%d | %d/%d | %d/%d | %d/%d |\n', ...
        L.txGain,L.frameCount,L.snrMean,L.snrSpread, ...
        L.singleHard(1),L.singleHard(2), L.singleCoh(1),L.singleCoh(2), ...
        L.singleJ7(1),L.singleJ7(2), L.avgHard(1),L.avgHard(2), ...
        L.perframeJ7(1),L.perframeJ7(2), L.jointJ7(1),L.jointJ7(2), ...
        L.jointHard(1),L.jointHard(2));
end
fclose(md);
end

function plotReport(levels, sweepDir)
snr = [levels.snrMean];
fig = figure('Color','w','Position',[80 80 980 620]);
names = {'单帧 硬判决','单帧 相干','单帧 joint7','逐帧同步+平均+硬', ...
         '逐帧同步+平均+joint7','联合同步+平均+joint7','联合同步+平均+硬'};
getf = {@(L)L.singleHard,@(L)L.singleCoh,@(L)L.singleJ7,@(L)L.avgHard, ...
        @(L)L.perframeJ7,@(L)L.jointJ7,@(L)L.jointHard};
hold on; grid on;
for m = 1:numel(names)
    y = zeros(1,numel(levels));
    for k = 1:numel(levels)
        v = getf{m}(levels(k));          % 先取向量：MATLAB 不允许 f(L)(1) 这种链式索引
        y(k) = 100*v(1)/max(v(2),1);
    end
    plot(snr, y, '-o','LineWidth',1.5,'DisplayName',names{m});
end
xlabel('实测 SNR / dB (2500 Hz)'); ylabel('正确解出率 / %');
title('真机灵敏度：零软件加噪'); legend('Location','southwest');
saveas(fig, fullfile(sweepDir,'sensitivity.png'));
end

function say(fmt,varargin)
fprintf([datestr(now,'HH:MM:SS') ' ' fmt '\n'], varargin{:});
end
