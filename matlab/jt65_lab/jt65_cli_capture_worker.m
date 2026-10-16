function jt65_cli_capture_worker(jobFile, resultFile, errorFile, stopFile, progressFile)
%JT65_CLI_CAPTURE_WORKER 子进程侧：读作业文件，执行真机采集，回写结果。
%   由 jt65_cli_capture 以 matlab -batch 启动，不供人工直接调用。
%   路径全部由参数传入（不写进 job.mat），这样即使作业文件损坏也能回写错误。
try
    S = load(jobFile,'p');
    p = S.p;
    b = jt65_capture_frames(p.Message, FrameCount=p.FrameCount, SpeedMode=p.SpeedMode, ...
        Serial=p.Serial, CenterFrequency=p.CenterFrequency, ...
        TxGain=p.TxGain, RxGain=p.RxGain, ...
        StopFcn=@() isfile(stopFile), ...
        ProgressFcn=@(i,sec,tot) writeProgress(progressFile, i, sec, tot));
    batch = b;
    save(resultFile,'batch');
catch ME
    writeError(errorFile, ME);
    rethrow(ME);   % 让 -batch 以非零退出码结束
end
end

function writeError(path, ME)
fid = fopen(path,'w');
if fid < 0, return; end
fprintf(fid,'%s\n', ME.message);
if isstruct(ME.stack) && ~isempty(ME.stack)
    for k = 1:numel(ME.stack)
        fprintf(fid,'  at %s line %d\n', ME.stack(k).name, ME.stack(k).line);
    end
end
fclose(fid);
end

function writeProgress(path, frameIndex, seconds, totalSeconds)
tmp = [path '.tmp'];
save(tmp,'frameIndex','seconds','totalSeconds');
movefile(tmp, path, 'f');
end
