function report = exp34_jt65_feature_sweep(sourceDir, opts)
%EXP34_JT65_FEATURE_SWEEP 量化各新增功能的灵敏度增益（真机录波 + 软件 AWGN）。
%   report = exp34_jt65_feature_sweep("某次 data/jt65_live_时间 的完整路径")
%
% 第 1 部分：单帧，四种组合对比
%   noncoherent+hard（原基线）与 coherent+hard
% 第 2 部分：多帧平均 N=1,2,4,8（非相干累加，理论 +10*log10(N) dB）
%   用同一条录波叠加独立噪声生成 N 帧，写到临时目录后调用 exp34_jt65_average，
%   因此测的是真实的平均实现，而不是另写一遍。
%
% 加噪口径与 exp34_jt65_snr_test 一致：先由高信噪比录波校准信号功率，再按
% noiseVar = (P/10^(SNR/10))*fsRx/B 设定复高斯噪声，使 B 带内噪声功率达到目标。
arguments
    sourceDir (1,1) string
    opts.Levels (1,:) double = -19:-1:-25
    opts.Trials (1,1) double {mustBeInteger,mustBePositive} = 10
    opts.Bandwidth (1,1) double {mustBePositive} = 2500
    opts.Seed (1,1) double {mustBeInteger,mustBeNonnegative} = 651013
    opts.AverageFrames (1,:) double = [1 2 4 8]
    opts.AverageLevels (1,:) double = -20:-2:-30
end
B = opts.Bandwidth; nT = opts.Trials;
C = load(fullfile(sourceDir,'rx_capture.mat'));
S = load(fullfile(sourceDir,'tx_reference.mat'));
rxClean = double(C.rx(:)); fsRx = C.fsRx; stats = C.stats;
work = tempname; mkdir(work);
save(fullfile(work,'tx_reference.mat'),'-struct','S');
rx = rxClean;
save(fullfile(work,'rx_capture.mat'),'rx','fsRx','stats');
evalc('base = exp34_jt65_live(ReplayDirectory=string(work),ShowPlots=false);');
assert(base.passed,'基准录波未解码，不能用作校准。');
cleanup = onCleanup(@() rmdir(work,'s'));
P = 10^(base.snr.signalDbFS/10);
Tframe = S.nSlot*S.nSamp/S.fs;
fStart = base.frameStartSeconds; fEnd = fStart+Tframe;
t = (0:numel(rxClean)-1).'/fsRx;
mask = (t<fStart-0.05) | (t>fEnd+0.05);
[psd,f] = pwelch(rxClean(mask),hann(4096,'periodic'),2048,16384,fsRx,'centered');
lim = S.fSync+[-B/2 B/2];
fb = [lim(1); f(f>lim(1)&f<lim(2)); lim(2)];
baseNoise = trapz(fb,interp1(f,psd,fb));
fprintf('信号功率 %.2f dBFS，本底(%.0f Hz) %.2f dBFS，符号 %.4f s\n', ...
    base.snr.signalDbFS,B,10*log10(baseNoise+realmin),Tframe);

modes = {
    '① 非相干 + 硬判决 (原基线)', "noncoherent", "hard"
    '② 相干   + 硬判决',          "coherent",    "hard"
};
nM = size(modes,1); nL = numel(opts.Levels);
rate = nan(nM,nL); symErr = nan(nM,nL);
fprintf('\n=== 第 1 部分：单帧 %d 种组合，%d 档 SNR，每档 %d 次 ===\n',nM,nL,nT);
for m = 1:nM
    for l = 1:nL
        lv = opts.Levels(l);
        added = P/10^(lv/10)-baseNoise;
        if added<=0, continue; end
        nv = added*fsRx/B; nOK = 0; se = zeros(nT,1);
        for k = 1:nT
            rng(opts.Seed+round(lv*100)*10+k,'twister');
            rx = rxClean+sqrt(nv/2)*(randn(size(rxClean))+1i*randn(size(rxClean)));
            save(fullfile(work,'rx_capture.mat'),'rx','fsRx','stats');
            try
                evalc('R=exp34_jt65_live(ReplayDirectory=string(work),ShowPlots=false,DetectionMode=modes{m,2},DecoderMode=modes{m,3});');
                nOK = nOK+R.passed; se(k) = R.symbolErrors;
            catch ME
                % 只把可预期的同步失败当作"未解码"；其他异常必须抛出，否则会像
                % 之前那样把代码错误伪装成 0% 成功率。
                if ~strcmp(ME.identifier,'JT65:SyncNotFound'), rethrow(ME); end
            end
            clearAnalysis(work);
        end
        rate(m,l) = nOK/nT; symErr(m,l) = median(se);
    end
    fprintf('%-28s',modes{m,1});
    fprintf(' | %s\n',sprintf('%2d/%d ',[round(rate(m,:)*nT); repmat(nT,1,nL)]));
end
fprintf('\n%-28s', 'SNR(dB)');
fprintf(' | %s\n', sprintf('%6.0f', opts.Levels));
fprintf('%-28s', '组合');
for m = 1:nM
    fprintf('\n%-28s | %s  | 符号错误中位: %s',modes{m,1}, ...
        sprintf('%5.0f%%',rate(m,:)*100), sprintf('%4.0f',symErr(m,:)));
end
fprintf('\n');

fprintf('\n=== 第 2 部分：多帧平均（非相干累加）===\n');
avgFrames = opts.AverageFrames; nA = numel(avgFrames); aL = numel(opts.AverageLevels);
avgRate = nan(nA,aL);
for a = 1:nA
    N = avgFrames(a);
    for l = 1:aL
        lv = opts.AverageLevels(l);
        added = P/10^(lv/10)-baseNoise;
        if added<=0, continue; end
        nv = added*fsRx/B; nOK = 0;
        for k = 1:nT
            groupDir = fullfile(work,sprintf('avg_%d_%d_%d',N,round(lv*10),k));
            mkdir(groupDir);
            for fr = 1:N
                fd = fullfile(groupDir,sprintf('frame_%05d',fr)); mkdir(fd);
                rng(opts.Seed+round(lv*100)*10+k*100+fr,'twister');
                rx = rxClean+sqrt(nv/2)*(randn(size(rxClean))+1i*randn(size(rxClean)));
                save(fullfile(fd,'rx_capture.mat'),'rx','fsRx','stats');
                save(fullfile(fd,'tx_reference.mat'),'-struct','S');
            end
            try
                evalc('rep=exp34_jt65_average(groupDir,DecoderMode="hard",ShowPlots=false);');
                if ~isempty(rep.groups) && rep.groups(1).accepted, nOK = nOK+1; end
            catch ME
                if ~strcmp(ME.identifier,'JT65:SyncNotFound'), rethrow(ME); end
            end
            rmdir(groupDir,'s');
        end
        avgRate(a,l) = nOK/nT;
    end
    fprintf('%-14s',sprintf('%d 帧 (+%.1f dB)',N,10*log10(N)));
    fprintf(' | %s\n',sprintf('%5.0f%%',avgRate(a,:)*100));
end
fprintf('\n%-14s | %s\n','SNR(dB)',sprintf('%6.0f',opts.AverageLevels));
report = struct('sourceDirectory',char(sourceDir),'bandwidthHz',B, ...
    'levels',opts.Levels,'trials',nT,'modes',{modes(:,1).'}, ...
    'frameSuccessRate',rate,'medianSymbolErrors',symErr, ...
    'averageFrames',avgFrames,'averageLevels',opts.AverageLevels,'averageSuccessRate',avgRate);
outDir = fullfile(sourceDir,['feature_sweep_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]);
mkdir(outDir);
save(fullfile(outDir,'feature_sweep.mat'),'report');
fprintf('\n结果已保存：%s\n',outDir);
end

function clearAnalysis(workDir)
d = dir(fullfile(workDir,'analysis_*'));
for i = 1:numel(d)
    if d(i).isdir, rmdir(fullfile(workDir,d(i).name),'s'); end
end
end
