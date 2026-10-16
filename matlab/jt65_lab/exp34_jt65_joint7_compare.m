function report=exp34_jt65_joint7_compare(opts)
% 对相同 IQ、相同同步结果比较原 RS 与七比特联合判决，不连接射频。
arguments
    opts.Trials (1,1) double {mustBeInteger,mustBePositive} = 10
    opts.ControlTrials (1,1) double {mustBeInteger,mustBePositive} = 20
end
root=fileparts(fileparts(fileparts(mfilename('fullpath'))));
out=fullfile(root,'data',['jt65_joint7_compare_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]); mkdir(out);
work=tempname; mkdir(work); cleanup=onCleanup(@()rmdir(work,'s'));
baseDir=fullfile(root,'data','jt65_loop_20261013_235220_622');
rows=cell(0,13); controls=cell(0,5);
for scenario=1:2
    if scenario==1, label="fast_recording"; levels=[-10 -12 -14 -16];
    else, label="slow_simulation"; levels=[-22 -24 -26 -28]; end
    for level=levels
        jointOK=0; hardOK=0; wrong=0;
        for trial=1:opts.Trials
            seed=651016+scenario*100000+round((level+50)*100)+trial;
            rng(seed,'twister');
            if scenario==1
                src=fullfile(baseDir,sprintf('frame_%05d',mod(trial-1,20)+1));
                S=load(fullfile(src,'tx_reference.mat')); C=load(fullfile(src,'rx_capture.mat'));
                original=double(C.rx); fsRx=C.fsRx; stats=C.stats;
                % 原始高 SNR 数据仅用于校准噪声功率，绝不向候选判决提供答案。
                evalc('base=exp34_jt65_live(ReplayDirectory=string(src),ShowPlots=false);');
                assert(base.passed); power=10^(base.snr.signalDbFS/10);
                variance=(power/10^(level/10)-base.snr.noiseDensity*2500)*fsRx/2500;
            else
                value=randi([0 127]); S=jt65_payload_frame(string(dec2bin(value,7)),1,SpeedMode="slow");
                fsRx=S.fs; guard=round(.2*fsRx); original=complex(zeros(2*guard+numel(S.wave),1));
                original(guard+(1:numel(S.wave)))=.3*S.wave;
                original=original.*exp(2i*pi*2.5*(0:numel(original)-1).'/fsRx);
                stats=struct('payloadUnderruns',0,'overruns',0,'emptyReads',0);
                variance=.09*fsRx/(2500*10^(level/10));
            end
            rx=original+sqrt(variance/2)*(randn(size(original))+1i*randn(size(original)));
            R=analyze(work,rx,fsRx,stats,S);
            [d,n]=jt65_rs_decode(R.validation.codedBits,R.diagnostics.mlEnergy,"hard");
            hardAccepted=n>=0; hardCorrect=hardAccepted && isequal(d(1:7),S.msgBits(1:7));
            jointCorrect=R.decoderAccepted && R.bitErrors==0;
            jointWrong=R.decoderAccepted && R.bitErrors>0;
            rows(end+1,:)={char(label),level,trial,seed,bin2dec(char(S.msgBits(1:7).'+48)), ...
                jointCorrect,jointWrong,~R.decoderAccepted,hardCorrect, ...
                hardAccepted && ~hardCorrect,~hardAccepted,R.rsDiagnostics.logEvidence,R.rsDiagnostics.logOdds}; %#ok<AGROW>
            jointOK=jointOK+jointCorrect; hardOK=hardOK+hardCorrect; wrong=wrong+jointWrong;
        end
        fprintf('%s %d dB：联合 %d/%d，原 RS %d/%d，联合误判 %d。\n',label,level,jointOK,opts.Trials,hardOK,opts.Trials,wrong);
    end
end
% 包含完整时间/频率搜索的纯噪声及持续数据单音控制。
for speed=["fast","slow"]
    S=jt65_payload_frame("1011010",1,SpeedMode=speed); fsRx=S.fs;
    count=numel(S.wave)+2*round(.2*fsRx); t=(0:count-1).'/fsRx;
    for k=1:opts.ControlTrials
        rng(951016+k+1000*(speed=="slow"),'twister');
        rx=(randn(count,1)+1i*randn(count,1))/sqrt(2);
        kind="noise";
        if k>opts.ControlTrials/2, rx=rx+3*exp(2i*pi*(S.fSync+2*S.df)*t); kind="tone"; end
        stats=struct('payloadUnderruns',0,'overruns',0,'emptyReads',0);
        R=analyze(work,rx,fsRx,stats,S);
        controls(end+1,:)={char(speed),char(kind),k,R.decoderAccepted,R.rsDiagnostics.logEvidence}; %#ok<AGROW>
    end
    fprintf('%s 完整同步拒判控制完成。\n',speed);
end
results=cell2table(rows,'VariableNames',{'Scenario','Snr2500Db','Trial','Seed','SentValue','JointCorrect','JointWrong','JointRejected','HardCorrect','HardWrong','HardRejected','LogEvidence','LogOdds'});
controlResults=cell2table(controls,'VariableNames',{'Speed','Kind','Trial','Accepted','LogEvidence'});
writetable(results,fullfile(out,'trials.csv')); writetable(controlResults,fullfile(out,'controls.csv'));
report=struct('directory',out,'results',results,'controls',controlResults,'referenceBandwidthHz',2500);
save(fullfile(out,'report.mat'),'report');
fprintf('结果：%s；完整同步控制误接收 %d/%d。\n',out,nnz(controlResults.Accepted),height(controlResults));
end

function R=analyze(work,rx,fsRx,stats,S)
save(fullfile(work,'tx_reference.mat'),'-struct','S');
save(fullfile(work,'rx_capture.mat'),'rx','fsRx','stats');
evalc('R=exp34_jt65_live(ReplayDirectory=string(work),ShowPlots=false,DecoderMode="joint7");');
% 测试中间图与大型结果已不需要，只保留指标和随机种子。
rmdir(R.outputDirectory,'s');
end
