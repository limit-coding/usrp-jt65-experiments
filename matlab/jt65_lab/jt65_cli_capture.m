function batch = jt65_cli_capture(varargin)
%JT65_CLI_CAPTURE 把真机采集甩给独立的 matlab -batch 子进程执行。
%   batch = jt65_cli_capture('Message',"hello",'FrameCount',6,'SpeedMode',"slow", ...)
%
%   为什么需要它：从 App（GUI 的 MATLAB 进程）直接调 jt65_capture_frames 时，
%   采集循环被 GUI 负载拖慢，TX/RX 时序错位——实测 13/13 帧的载荷起点偏到 5–23 秒
%   （正常应 0.33–0.40 秒），整档作废。同一组参数用命令行跑则 6/6 正常。
%   本函数在 GUI 里保持同样的调用形式，实际采集发生在另一个干净的 MATLAB 进程里。
%
%   参数与 jt65_capture_frames 同名同义；StopFcn / ProgressFcn 仍可用：
%   StopFcn 返回 true 时通过标志文件请求子进程停止，ProgressFcn 由子进程写入、
%   本函数轮询读出后回放。轮询期间 pause+drawnow，界面保持响应。
%
%   返回的 batch 与 jt65_capture_frames 的返回结构一致。
opt = jt65_cli_parse(varargin{:});

labDir = fileparts(mfilename('fullpath'));
jobDir = fullfile(tempdir, ['jt65cli_' char(datetime('now','Format','yyyymmddHHMMSSSSS'))]);
mkdir(jobDir);
jobFile      = fullfile(jobDir,'job.mat');
resultFile   = fullfile(jobDir,'result.mat');
errorFile    = fullfile(jobDir,'error.txt');
stopFile     = fullfile(jobDir,'stop.flag');
progressFile = fullfile(jobDir,'progress.mat');
logFile      = fullfile(jobDir,'child.log');

p = struct('Message',opt.Message,'FrameCount',opt.FrameCount,'SpeedMode',opt.SpeedMode, ...
    'Serial',opt.Serial,'CenterFrequency',opt.CenterFrequency, ...
    'TxGain',opt.TxGain,'RxGain',opt.RxGain);
save(jobFile,'p');

matlabExe = fullfile(matlabroot,'bin','matlab');
assert(isfile(matlabExe),'找不到 matlab 可执行文件：%s',matlabExe);
cmd = sprintf(['%s -batch "cd(''%s''); jt65_cli_capture_worker(''%s'',''%s'',''%s'',''%s'',''%s'')" ' ...
    '> ''%s'' 2>&1 &'], ...
    matlabExe, labDir, jobFile, resultFile, errorFile, stopFile, progressFile, logFile);
[st,msg] = system(cmd);
assert(st==0,'无法启动子进程：%s',msg);

T = jt65_timing(opt.SpeedMode);
nFrames = opt.FrameCount;
if isnan(nFrames), nFrames = T.minuteFrames; end
maxWait = nFrames*T.frameSeconds + 600;      % 采集时间 + 10 分钟余量（含两次 MATLAB 启动）
fprintf('子进程采集已启动：%d 帧，预计 %.1f 分钟（超时上限 %.1f 分钟）\n', ...
    nFrames, nFrames*T.frameSeconds/60, maxWait/60);

cleanup = onCleanup(@() cliCleanup(jobDir, errorFile));
t0 = tic;
while ~isfile(resultFile) && ~isfile(errorFile)
    if toc(t0) > maxWait
        system(sprintf('pkill -f %s >/dev/null 2>&1', jobDir));   % 尽力而为地收掉子进程
        error('子进程采集超时（%.0f 分钟）。子进程日志：%s', maxWait/60, logFile);
    end
    if ~isempty(opt.StopFcn) && opt.StopFcn()
        fclose(fopen(stopFile,'w'));
    end
    if ~isempty(opt.ProgressFcn) && isfile(progressFile)
        try
            pr = load(progressFile);
            if isfield(pr,'frameIndex')
                opt.ProgressFcn(pr.frameIndex, pr.seconds, pr.totalSeconds);
            end
        catch
            % 进度文件可能正在写入，下一轮再读。
        end
    end
    pause(0.5); drawnow;
end
if isfile(errorFile)
    error('子进程采集失败：%s\n子进程日志：%s', strtrim(fileread(errorFile)), logFile);
end
S = load(resultFile,'batch');
batch = S.batch;
end

function o = jt65_cli_parse(varargin)
ip = inputParser;
addParameter(ip,'Message',"hello");
addParameter(ip,'FrameCount',NaN);
addParameter(ip,'SpeedMode',"fast");
addParameter(ip,'Serial',"");
addParameter(ip,'CenterFrequency',435e6);
addParameter(ip,'TxGain',30);
addParameter(ip,'RxGain',40);
addParameter(ip,'StopFcn',[]);
addParameter(ip,'ProgressFcn',[]);
parse(ip,varargin{:});
o = ip.Results;
end

function cliCleanup(jobDir, errorFile)
if isfile(errorFile)
    fprintf('子进程出错，工作目录保留供排查：%s\n', jobDir);
else
    try
        rmdir(jobDir,'s');
    catch
        % 清理失败不影响返回结果。
    end
end
end
