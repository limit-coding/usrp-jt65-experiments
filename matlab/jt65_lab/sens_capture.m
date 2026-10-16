function index = sens_capture(varargin)
%SENS_CAPTURE 真机灵敏度扫描采集：只调 TxGain/RxGain 两个物理旋钮，绝不加任何软件噪声。
%   index = sens_capture('TxGains',8:-1:0,'FramesPerLevel',6)
%
%   每个发射增益档连续采 FramesPerLevel 帧慢速 hello 录波；每档结束立即写
%   index.mat，中途失败不丢已完成的数据。输出目录 data/sens_sweep_<时间戳>/。
%
%   本函数只做采集，不做判决。分析见 sens_analyze.m。
p = inputParser;
addParameter(p,'TxGains',8:-1:0);
addParameter(p,'FramesPerLevel',6);
addParameter(p,'RxGain',40);
addParameter(p,'Message',"hello");
addParameter(p,'CenterFrequency',435e6);
addParameter(p,'Serial',"");
addParameter(p,'OutRoot',"");
parse(p,varargin{:});
o = p.Results;

root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
if strlength(o.OutRoot) == 0
    outRoot = fullfile(root,'data',['sens_sweep_' char(datetime('now','Format','yyyyMMdd_HHmmss'))]);
else
    outRoot = char(o.OutRoot);
end
mkdir(outRoot);

T = jt65_timing("slow");
perLevelSeconds = o.FramesPerLevel*T.frameSeconds;
say('OUTROOT=%s', outRoot);
say('档位 %s；每档 %d 帧；预计采集 %.1f 分钟（含设备启动与逐帧降采样落盘）', ...
    mat2str(o.TxGains), o.FramesPerLevel, numel(o.TxGains)*perLevelSeconds/60);
say('消息 "%s"，时序 slow（每帧 %.2f s），RxGain %.1f，中心 %.3f MHz', ...
    o.Message, T.frameSeconds, o.RxGain, o.CenterFrequency/1e6);

index = emptyIndex();
save(fullfile(outRoot,'index.mat'),'index');

t0 = tic;
for k = 1:numel(o.TxGains)
    tg = o.TxGains(k);
    say('[%s] 档 %d/%d：TxGain %.1f dB 开始（累计已用 %.1f 分钟）', ...
        datestr(now,'HH:MM:SS'), k, numel(o.TxGains), tg, toc(t0)/60);
    try
        b = jt65_capture_frames(o.Message, FrameCount=o.FramesPerLevel, SpeedMode="slow", ...
            Serial=o.Serial, CenterFrequency=o.CenterFrequency, TxGain=tg, RxGain=o.RxGain);
        row = struct('txGain',tg,'rxGain',o.RxGain,'directory',string(b.outputDirectory), ...
            'frameCount',b.frameCount,'ok',true,'error',"");
        say('    完成：%d 帧 → %s', b.frameCount, b.outputDirectory);
    catch ME
        row = struct('txGain',tg,'rxGain',o.RxGain,'directory',"", ...
            'frameCount',0,'ok',false,'error',string(ME.message));
        say('    失败：%s', ME.message);
    end
    index(end+1) = row; %#ok<AGROW>
    save(fullfile(outRoot,'index.mat'),'index');
end
say('采集结束：%d/%d 档成功，总用时 %.1f 分钟；OUTROOT=%s', ...
    nnz([index.ok]), numel(o.TxGains), toc(t0)/60, outRoot);
end

function idx = emptyIndex()
idx = struct('txGain',{},'rxGain',{},'directory',{},'frameCount',{},'ok',{},'error',{});
end

function say(fmt,varargin)
fprintf([datestr(now,'HH:MM:SS') ' ' fmt '\n'], varargin{:});
end
