function report = exp34_jt65_snr_test(sourceDir,opts)
%EXP34_JT65_SNR_TEST 真机录波加复高斯白噪声，测试现有接收程序。
% report = exp34_jt65_snr_test("某次 jt65_live_时间 目录")
% 不连接 USRP。SyncMode 选择 joint/legacy，种子一致可作公平对照。
% SNR 由高信噪比原始录波校准信号功率后，按已知加噪功率设定。
% 不以低 SNR 下不稳定的“两个大功率相减”作为实际测试横坐标。
arguments
    sourceDir (1,1) string
    opts.Levels (1,:) double = -5:-5:-30
    opts.Trials (1,1) double {mustBeInteger,mustBePositive} = 20
    opts.Bandwidths (1,:) double {mustBePositive} = [400 2500]
    opts.Seed (1,1) double {mustBeInteger,mustBeNonnegative} = 651013
    opts.SyncMode (1,1) string {mustBeMember(opts.SyncMode,["joint","legacy"])} = "joint"
end
sourceDir=char(sourceDir);
C=load(fullfile(sourceDir,'rx_capture.mat'));
S=load(fullfile(sourceDir,'tx_reference.mat'));
original=double(C.rx(:)); fsRx=C.fsRx;
assert(fsRx==S.fs,'采样率不一致');
assert(all(opts.Bandwidths<=fsRx),'参考带宽不能大于采样带宽');
outDir=fullfile(sourceDir,['snr_test_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]);
mkdir(outDir);
copyfile(which('exp34_jt65_live'),fullfile(outDir,'exp34_jt65_live.m'));
copyfile([mfilename('fullpath') '.m'],fullfile(outDir,'exp34_jt65_snr_test.m'));
workDir=tempname; mkdir(workDir);
cleanup=onCleanup(@() rmdir(workDir,'s'));
save(fullfile(workDir,'tx_reference.mat'),'-struct','S');
rx=original; stats=C.stats;
save(fullfile(workDir,'rx_capture.mat'),'rx','fsRx','stats');
evalc('base=exp34_jt65_live(ReplayDirectory=string(workDir),ShowPlots=false,SyncMode="legacy");');
evalc('setup=exp34_jt65_live(ReplayDirectory=string(workDir),ShowPlots=false,SyncMode=opts.SyncMode);');
syncThreshold=setup.diagnostics.threshold;
assert(base.passed,'原始录波不能正确解码，不能用作校准基准');
signalPower=10^(base.snr.signalDbFS/10);
time=(0:numel(original)-1).'/fsRx;
frameEnd=base.frameStartSeconds+S.nSlot*S.nSamp/S.fs;
noiseMask=(time>=0.5 & time<base.frameStartSeconds-0.5) | ...
    (time>frameEnd+0.5 & time<time(end)-0.5);
[noisePsd,f]=pwelch(original(noiseMask),hann(4096,'periodic'),2048,16384,fsRx,'centered');
nB=numel(opts.Bandwidths); nL=numel(opts.Levels); nT=opts.Trials;
syncOK=false(nB,nL,nT); passed=syncOK;
ber=nan(nB,nL,nT); symbolErrors=ber; syncScore=ber; frameStart=ber;
noiseVariance=zeros(nB,nL); baselineNoisePower=zeros(1,nB);
failure=strings(nB,nL,nT); seed=zeros(nB,nL,nT);
logF=fopen(fullfile(outDir,'summary.txt'),'w');
assert(logF>=0,'不能创建测试日志');
logCleanup=onCleanup(@() fclose(logF));
say(logF,'真机录波 + 软件 AWGN 测试（不是新的空口弱信号测试）\n');
say(logF,'原始消息 %s；信号功率 %.3f dBFS；原始 400 Hz SNR %.3f dB\n', ...
    S.userMsg,10*log10(signalPower),base.snr.bandDb);
say(logF,'每档 %d 次；同步方式 %s，门限 %.3f。\n',nT,opts.SyncMode,syncThreshold);
for b=1:nB
    B=opts.Bandwidths(b);
    if B==400, limits=[1150 1550]; else, limits=S.fSync+[-B/2 B/2]; end
    fb=[limits(1);f(f>limits(1) & f<limits(2));limits(2)];
    baselineNoisePower(b)=trapz(fb,interp1(f,noisePsd,fb));
    for l=1:nL
        target=opts.Levels(l);
        addedBandPower=signalPower/10^(target/10)-baselineNoisePower(b);
        assert(addedBandPower>0,'目标 SNR 高于原始录波，无法通过加噪达到');
        noiseVariance(b,l)=addedBandPower*fsRx/B;
        for k=1:nT
            % 由带宽、SNR、重复编号固定种子；细扫重跑也可复现同一条件。
            seed(b,l,k)=opts.Seed+round(B)*100000+round((target+100)*100)*100+k;
            rng(seed(b,l,k),'twister');
            noise=sqrt(noiseVariance(b,l)/2)*(randn(size(original))+1i*randn(size(original)));
            rx=original+noise;
            save(fullfile(workDir,'rx_capture.mat'),'rx','fsRx','stats');
            try
                evalc('R=exp34_jt65_live(ReplayDirectory=string(workDir),ShowPlots=false,SyncMode=opts.SyncMode);');
                syncOK(b,l,k)=true; passed(b,l,k)=R.passed;
                ber(b,l,k)=R.ber; symbolErrors(b,l,k)=R.symbolErrors;
                syncScore(b,l,k)=R.syncScore; frameStart(b,l,k)=R.frameStartSeconds;
            catch ME
                % 只将已知同步门限拒绝视为测试失败；其他代码错误向上传播。
                if ~strcmp(ME.identifier,'JT65:SyncNotFound') && ~contains(ME.message,'未达到 0.50')
                    rethrow(ME);
                end
                failure(b,l,k)=string(ME.message);
                token=regexp(ME.message,'得分 ([\d.]+) 未达到','tokens','once');
                if ~isempty(token), syncScore(b,l,k)=str2double(token{1}); end
            end
            % 保留指标和种子，删除临时回放结果，避免产生数 GB 中间文件。
            analysisDirs=dir(fullfile(workDir,'analysis_*'));
            for d=1:numel(analysisDirs)
                if analysisDirs(d).isdir
                    rmdir(fullfile(workDir,analysisDirs(d).name),'s');
                end
            end
        end
        say(logF,'B=%4d Hz | SNR=%6.1f dB | 同步 %2d/%d | 整帧正确 %2d/%d | 同步得分 %.3f..%.3f\n', ...
            B,target,nnz(syncOK(b,l,:)),nT,nnz(passed(b,l,:)),nT, ...
            min(syncScore(b,l,:)),max(syncScore(b,l,:)));
    end
end
report=struct('sourceDirectory',sourceDir,'outputDirectory',outDir,'options',opts, ...
    'signalPower',signalPower,'baselineNoisePower',baselineNoisePower, ...
    'addedNoiseVariance',noiseVariance,'seeds',seed,'syncOK',syncOK,'passed',passed, ...
    'berAmongSynchronized',ber,'symbolErrors',symbolErrors,'syncScore',syncScore, ...
    'frameStartSeconds',frameStart,'failures',failure, ...
    'syncThreshold',syncThreshold, ...
    'syncRate',mean(syncOK,3),'frameSuccessRate',mean(passed,3));
report.limit50Db=nan(1,nB); report.limit90Db=nan(1,nB);
for b=1:nB
    good=opts.Levels(report.frameSuccessRate(b,:)>=0.5);
    if ~isempty(good), report.limit50Db(b)=min(good); end
    good=opts.Levels(report.frameSuccessRate(b,:)>=0.9);
    if ~isempty(good), report.limit90Db(b)=min(good); end
    say(logF,'B=%d Hz：已测点中 >=50%% 成功的最低 SNR %.1f dB，>=90%% 成功的最低 SNR %.1f dB。\n', ...
        opts.Bandwidths(b),report.limit50Db(b),report.limit90Db(b));
end
say(logF,'门限只针对本条录波、当前接收机及 AWGN 模型；不是 JT65 理论极限。\n');
say(logF,'未同步帧计入整帧失败，不伪造 BER=0。同步后的 BER 保存在结果中。\n');
save(fullfile(outDir,'snr_report.mat'),'report');
fig=figure('Color','w','Position',[50 80 1400 800],'Name','JT65 加噪极限测试');
tiledlayout(2,2,'TileSpacing','compact','Padding','compact');
sgtitle(sprintf('JT65：真机录波 + AWGN | 每档 %d 次 | %s 同步，门限 %.3f',nT,opts.SyncMode,syncThreshold), ...
    'FontSize',16,'FontWeight','bold');
labels=compose('%d Hz 参考带宽',opts.Bandwidths);
nexttile; hold on; grid on;
for b=1:nB, plot(opts.Levels,100*report.frameSuccessRate(b,:),'-o','LineWidth',1.5); end
yline(50,':','50%'); yline(90,':','90%'); ylim([-3 103]);
xlabel('校准目标 SNR (dB)'); ylabel('整帧正确率 (%)');
legend(labels,'Location','northwest'); title('① 同步成功且 72 bit 全部正确');
nexttile; hold on; grid on;
for b=1:nB, plot(opts.Levels,100*report.syncRate(b,:),'-o','LineWidth',1.5); end
ylim([-3 103]); xlabel('校准目标 SNR (dB)'); ylabel('同步通过率 (%)');
legend(labels,'Location','northwest'); title('② 未同步也计入失败');
nexttile; hold on; grid on;
for b=1:nB
    plot(opts.Levels,mean(syncScore(b,:,:),3),'-o','LineWidth',1.5);
end
yline(syncThreshold,'--',sprintf('程序门限 %.3f',syncThreshold)); xlabel('校准目标 SNR (dB)'); ylabel('平均同步得分');
legend(labels,'Location','northwest'); title('③ 判断是否受同步门限限制');
nexttile; axis off;
text(0,0.95,'④ 测试口径与可复现结果','FontSize',13,'FontWeight','bold');
lines={sprintf('输入：原始真机录波 "%s"，叠加复高斯白噪声',S.userMsg), ...
    sprintf('每档 %d 个噪声种子；失败帧不从统计中剔除',nT), ...
    sprintf('400 Hz 与 2500 Hz 的白噪声口径相差 %.2f dB',10*log10(2500/400)), ...
    '先用高 SNR 原始录波校准，再按已知功率加噪', ...
    '低 SNR 处不使用帧内、帧外功率相减校准横坐标', ...
    '曲线是当前程序表现，不代表 JT65 理论极限', ...
    '并非新做的空口弱信号测试，也未引入大频偏'};
for k=1:numel(lines), text(0,0.82-(k-1)*0.11,lines{k},'FontSize',11,'Interpreter','none'); end
axesList=findall(fig,'Type','axes');
for k=1:numel(axesList), axesList(k).Toolbar.Visible='off'; end
exportgraphics(fig,fullfile(outDir,'snr_sweep.png'),'Resolution',150);
fprintf('测试结果：%s\n',outDir);
end

function say(fid,varargin)
text=sprintf(varargin{:}); fprintf('%s',text); fprintf(fid,'%s',text);
end
