function report = exp34_jt65_hardware_test(opts)
%EXP34_JT65_HARDWARE_TEST B210 真机验收：默认路径回归 + 新增功能对比 + 发射增益扫描。
%   report = exp34_jt65_hardware_test()                      % 默认跑全流程
%   report = exp34_jt65_hardware_test(TxGains=[30 24],FramesPerGain=2)
%
% 流程
%   0) 回归：默认路径（快速时序 + 相干关 + 硬判决）单帧收发，行为应与改动前一致。
%   1) 增益扫描：每组用一次连续采集收 N 帧，逐帧用四种组合回放分析：
%        非相干+硬（基线）、相干+硬、非相干+软、相干+软
%      降低发射增益即降低接收信噪比，从而在真实空口上比较灵敏度。
%      灵敏度对比用慢速时序（= 实验四课件规定的 11025 S/s、Δf=2.69 Hz）。
%   2) 多帧平均：对最低增益那组用 exp34_jt65_average 做多帧累加，看能否把单帧
%      解不出的帧收回来。
%
% 安全：默认 435 MHz、发射增益不超过 30 dB，接法与既有实验一致（TX/RX 接发射
% 天线，RX2 接接收天线）。请先确认当地无线电规定并接好天线再运行。
arguments
    opts.Serial (1,1) string = ""
    opts.CenterFrequency (1,1) double = 435e6
    opts.RxGain (1,1) double = 40
    opts.TxGains (1,:) double = [30 24 18]
    opts.FramesPerGain (1,1) double = 3
    opts.Message (1,1) string = "1011010"
    opts.SpeedMode (1,1) string {mustBeMember(opts.SpeedMode,["fast","slow"])} = "slow"
    opts.SkipRegression (1,1) logical = false
end
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
outDir = fullfile(root,'data',['jt65_hwtest_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]);
mkdir(outDir);
fid = fopen(fullfile(outDir,'hwtest.log'),'w');
assert(fid>=0,'无法创建日志。');
cleanupObj = onCleanup(@() fclose(fid)); %#ok<NASGU>
sayf = @(varargin) fprintfBoth(fid,varargin{:});
sayf('\n===== B210 真机验收 =====\n');
sayf('中心频率 %.3f MHz | RX 增益 %.1f dB | 时序 %s | 消息 "%s"\n', ...
    opts.CenterFrequency/1e6,opts.RxGain,opts.SpeedMode,opts.Message);
T = jt65_timing(opts.SpeedMode);
sayf('每帧正文 %.2f 秒，%d 帧/组约 %.1f 秒\n',T.payloadSeconds, ...
    opts.FramesPerGain,opts.FramesPerGain*T.frameSeconds);

report = struct('outputDirectory',outDir,'options',opts);

%% 0) 默认路径回归
if ~opts.SkipRegression
    sayf('\n--- 0) 默认路径回归（快速时序，相干关，硬判决）---\n');
    try
        R = exp34_jt65_live(opts.Message,Serial=opts.Serial, ...
            CenterFrequency=opts.CenterFrequency,RxGain=opts.RxGain,ShowPlots=false);
        sayf('回归：符号错误 %d/63，消息 "%s"，通过 %d\n',R.symbolErrors,R.message,R.passed);
        report.regression = struct('passed',R.passed,'symbolErrors',R.symbolErrors, ...
            'message',R.message,'directory',R.outputDirectory);
    catch ME
        sayf('回归失败：%s\n',ME.message);
        report.regression = struct('passed',false,'error',ME.message);
    end
end

%% 1) 发射增益扫描
modes = {
    '非相干 + 硬判决（基线）', "noncoherent", "hard"
    '相干   + 硬判决',        "coherent",    "hard"
};
nM = size(modes,1); nG = numel(opts.TxGains);
ok = nan(nG,nM); symErr = nan(nG,nM); snap = nan(nG,nM); badFrame = zeros(nG,nM);
groupDirs = strings(1,nG);
for g = 1:nG
    tg = opts.TxGains(g);
    sayf('\n--- 1) 发射增益 %.1f dB：连续采集 %d 帧 ---\n',tg,opts.FramesPerGain);
    try
        batch = jt65_capture_frames(opts.Message,FrameCount=opts.FramesPerGain, ...
            SpeedMode=opts.SpeedMode,Serial=opts.Serial, ...
            CenterFrequency=opts.CenterFrequency,TxGain=tg,RxGain=opts.RxGain);
        groupDirs(g) = string(batch.outputDirectory);
    catch ME
        sayf('采集失败：%s\n',ME.message);
        continue;
    end
    frameDirs = discoverFrames(batch.outputDirectory);
    sayf('采集目录 %s（%d 帧）\n',batch.outputDirectory,numel(frameDirs));
    for m = 1:nM
        nOK = 0; se = nan(numel(frameDirs),1); sc = nan(numel(frameDirs),1); nb = 0;
        for k = 1:numel(frameDirs)
            try
                R = exp34_jt65_live(ReplayDirectory=frameDirs{k},ShowPlots=false, ...
                    DetectionMode=modes{m,2},DecoderMode=modes{m,3});
                nOK = nOK+R.passed; se(k) = R.symbolErrors; sc(k) = R.syncScore;
            catch ME
                if ~strcmp(ME.identifier,'JT65:SyncNotFound'), rethrow(ME); end
                nb = nb+1;
            end
            cleanupAnalysis(frameDirs{k});
        end
        ok(g,m) = nOK/numel(frameDirs);
        symErr(g,m) = median(se,'omitnan');
        snap(g,m) = median(sc,'omitnan');
        badFrame(g,m) = nb;
        sayf('  %-24s %d/%d 解出，符号错误中位 %.0f，同步得分中位 %.3f%s\n', ...
            modes{m,1},nOK,numel(frameDirs),symErr(g,m),snap(g,m), ...
            ternary(nb>0,sprintf('，%d 帧同步失败',nb),''));
    end
    report.groups(g) = struct('txGainDb',tg,'directory',batch.outputDirectory, ...
        'frameCount',numel(frameDirs));
end

sayf('\n=== 增益扫描汇总（解出帧数 / 总帧数）===\n');
sayf('%-12s','发射增益');
for m = 1:nM, sayf(' | %-20s',modes{m,1}); end
sayf('\n');
for g = 1:nG
    sayf('%-12s',sprintf('%.0f dB',opts.TxGains(g)));
    for m = 1:nM
        sayf(' | %-20s',sprintf('%d/%d (符号错 %.0f)',round(ok(g,m)*opts.FramesPerGain), ...
            opts.FramesPerGain,symErr(g,m)));
    end
    sayf('\n');
end
report.frameSuccessRate = ok; report.medianSymbolErrors = symErr;
report.medianSyncScore = snap; report.syncFailureFrames = badFrame;

%% 2) 多帧平均（用最低增益那组，也就是最难的一组）
gLow = find(~isnan(ok(:,1)),1,'last');
if ~isempty(gLow) && strlength(groupDirs(gLow))>0
    sayf('\n--- 2) 多帧平均：对 %.0f dB 那组做非相干累加 ---\n',opts.TxGains(gLow));
    try
        rep = exp34_jt65_average(groupDirs(gLow),DecoderMode="hard",ShowPlots=false);
        for k = 1:numel(rep.groups)
            gr = rep.groups(k);
            sayf('组 %d：%d 帧平均（等效 +%.2f dB）→ 符号错误 %d/63，%s，消息 "%s"\n', ...
                gr.group,gr.frames,gr.equivalentGainDb,gr.symbolErrors, ...
                ternary(gr.accepted,'解出','未解出'),gr.message);
        end
        report.averaging = rep;
    catch ME
        sayf('多帧平均失败：%s\n',ME.message);
        report.averaging = struct('error',ME.message);
    end
end

save(fullfile(outDir,'hwtest_report.mat'),'report');
sayf('\n报告已保存：%s\n',fullfile(outDir,'hwtest_report.mat'));
end

function dirs = discoverFrames(groupDir)
sub = dir(fullfile(groupDir,'frame_*'));
dirs = {};
for k = 1:numel(sub)
    if sub(k).isdir && isfile(fullfile(groupDir,sub(k).name,'rx_capture.mat'))
        dirs{end+1} = fullfile(groupDir,sub(k).name); %#ok<AGROW>
    end
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

function fprintfBoth(fid,varargin)
% 同时写命令窗口和日志文件。
fprintf(varargin{:});
fprintf(fid,varargin{:});
end
