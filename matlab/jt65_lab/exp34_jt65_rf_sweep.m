function report=exp34_jt65_rf_sweep(opts)
% 真机增益扫描：不添加软件噪声。每行 [TX增益 RX增益]；每点可重复多帧。
% report=exp34_jt65_rf_sweep(GainPairs=[20 40;20 60;20 70],Trials=1)
arguments
    opts.GainPairs (:,2) double = [20 40;20 60;20 70]
    opts.Trials (1,1) double {mustBeInteger,mustBePositive} = 1
    opts.Serial (1,1) string = ""
    opts.CenterFrequency (1,1) double {mustBePositive} = 435e6
end
root=fileparts(fileparts(fileparts(mfilename('fullpath'))));
outDir=fullfile(root,'data',['real_rf_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]); mkdir(outDir);
report=struct('options',opts,'outputDirectory',outDir,'rows',[]);
for k=1:size(opts.GainPairs,1)
    for trial=1:opts.Trials
        txGain=opts.GainPairs(k,1); rxGain=opts.GainPairs(k,2);
        folder=fullfile(outDir,sprintf('point%02d_tx%g_rx%g_trial%02d',k,txGain,rxGain,trial));
        fprintf('\n=== 真机扫描 %d/%d：TX %g RX %g，重复 %d ===\n',k,size(opts.GainPairs,1),txGain,rxGain,trial);
        msg=sprintf('RF%02dT%02d',k,trial);
        C=exp34_jt65_live(string(msg),TxGain=txGain,RxGain=rxGain, ...
            Serial=opts.Serial,CenterFrequency=opts.CenterFrequency, ...
            CaptureOnly=true,ShowPlots=false,OutputDirectory=folder);
        row=struct('txGain',txGain,'rxGain',rxGain,'trial',trial,'captureDirectory',folder, ...
            'syncOK',false,'hardPassed',false,'erasurePassed',false,'symbolErrors',NaN, ...
            'pilotSnr2500Db',NaN,'rawRmsDbFS',C.radioStats.rxRawRmsDbFS, ...
            'rawPeakDbFS',C.radioStats.rxRawPeakDbFS,'clippedSamples',C.radioStats.rxClippedSamples, ...
            'transportClean',C.radioStats.payloadUnderruns==0 && C.radioStats.overruns==0 && C.radioStats.emptyReads==0,'failure','');
        try
            H=exp34_jt65_live(ReplayDirectory=folder,DecoderMode="hard",ShowPlots=false);
            E=exp34_jt65_live(ReplayDirectory=folder,DecoderMode="erasure",ShowPlots=false);
            row.syncOK=true; row.hardPassed=H.passed; row.erasurePassed=E.passed;
            row.symbolErrors=H.symbolErrors; row.pilotSnr2500Db=H.snr.pilot.snr2500Db;
            save(fullfile(folder,'comparison.mat'),'H','E');
        catch err
            if ~strcmp(err.identifier,'JT65:SyncNotFound'), rethrow(err); end
            row.failure=err.message;
        end
        report.rows=[report.rows;row]; %#ok<AGROW>
        save(fullfile(outDir,'rf_report.mat'),'report');
        writetable(struct2table(report.rows),fullfile(outDir,'rf_summary.csv'));
        fprintf('本点：同步 %d，硬判决正确 %d，擦除译码正确 %d，SNR2500 %.2f dB，ADC峰值 %.1f dBFS，削顶 %d\n', ...
            row.syncOK,row.hardPassed,row.erasurePassed,row.pilotSnr2500Db,row.rawPeakDbFS,row.clippedSamples);
    end
end
fprintf('真机扫描结果：%s\n',outDir);
end
