classdef JT65LabApp < matlab.apps.AppBase
    % 原生 MATLAB 展示 App；实验完成后统一绘图，不在采集中刷新窗口。
    properties (Access=public)
        UIFigure
        ModeField
        SpeedModeField
        DecoderModeField
        DetectionModeField
        TimingLabel
        MessageField
        SourceField
        SourceButton
        NoiseCheck
        BandwidthField
        SnrField
        SnrSlider
        NoiseButton
        OffsetField
        CenterField
        SerialField
        TxGainField
        RxGainField
        LoopCheck
        LoopPresetField
        FrameCountField
        StopButton
        Cumulative=[]
        RunButton
        ExportButton
        Tabs
        StatusLabel
        ResultLabel
        CardValues
        CardTitles
        Axes
        LastResult=[]
        LastError=''
    end
    properties (Access=private)
        Busy=false
        StopRequested=false
        NoiseSeed=20261013
        Controls
        RootDirectory
    end
    methods (Access=public)
        function app=JT65LabApp(varargin)
            p=inputParser; addParameter(p,'Visible','on'); addParameter(p,'AutoRun',true); parse(p,varargin{:});
            app.RootDirectory=fileparts(fileparts(fileparts(mfilename('fullpath'))));
            app.createComponents(p.Results.Visible);
            registerApp(app,app.UIFigure);
            app.updateMode();
            if p.Results.AutoRun, app.runExperiment(); end
            if nargout==0, clear app; end
        end
        function runExperiment(app,strict)
            if nargin<2, strict=false; end
            if app.Busy, return; end
            app.LastError=''; app.StopRequested=false; app.Cumulative=[];
            cfg=app.readConfig();
            if cfg.Mode~="录波回放"
                try
                    jt65_payload_frame(string(cfg.Message),1,SpeedMode=string(cfg.SpeedMode));
                catch ME
                    app.LastError=ME.message;
                    if strict, rethrow(ME); end
                    uialert(app.UIFigure,ME.message,'发送内容需要调整'); return;
                end
            end
            app.Busy=true; app.setEnabled(false);
            app.StopButton.Enable=matlab.lang.OnOffSwitchState(cfg.Mode=="USRP 真机收发");
            app.StatusLabel.Text='正在运行，请等待完成后查看图表……';
            dialog=uiprogressdlg(app.UIFigure,'Title','JT65 实验进行中', ...
                'Message','准备采集或分析。','Indeterminate','on','Cancelable','on', ...
                'CancelText','收完当前帧后停止');
            drawnow;
            caught=[]; summaryDir='';
            try
                if cfg.Mode=="USRP 真机收发"
                    dialog.Message='连续收发中；整组采集结束后再分析，避免中断采样。';
                    batch=jt65_capture_frames(string(cfg.Message),FrameCount=cfg.FrameCount,SpeedMode=string(cfg.SpeedMode), ...
                        Serial=string(cfg.Serial),CenterFrequency=cfg.CenterMHz*1e6, ...
                        TxGain=cfg.TxGain,RxGain=cfg.RxGain, ...
                        StopFcn=@()app.StopRequested || dialog.CancelRequested, ...
                        ProgressFcn=@(i,t,total)app.captureProgress(dialog,i,t,total));
                    directories={batch.captures.directory}; summaryDir=batch.outputDirectory;
                    dialog.Cancelable='off'; app.StopButton.Enable='off';
                elseif cfg.Mode=="录波回放" && isfile(fullfile(cfg.SourceDirectory,'batch.mat'))
                    saved=load(fullfile(cfg.SourceDirectory,'batch.mat'),'batch');
                    directories={saved.batch.captures.directory};
                    summaryDir=fullfile(cfg.SourceDirectory,['analysis_' char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))]);
                    mkdir(summaryDir);
                else
                    directories={''};
                end
                for i=1:numel(directories)
                    dialog.Message=sprintf('正在分析第 %d / %d 帧……',i,numel(directories)); drawnow;
                    frameCfg=cfg;
                    if cfg.Mode=="USRP 真机收发", frameCfg.CaptureDirectory=directories{i};
                    elseif cfg.Mode=="录波回放" && ~isempty(directories{i}), frameCfg.SourceDirectory=directories{i}; end
                    P=jt65_demo_run(frameCfg);
                    app.LastResult=P; app.Cumulative=jt65_accumulate(app.Cumulative,P);
                    if mod(i,5)==0 || i==numel(directories)
                        app.renderResult(P); app.renderCumulative();
                    end
                    if isempty(summaryDir), summaryDir=P.outputDirectory; end
                    cumulative=app.Cumulative;
                    save(fullfile(summaryDir,'cumulative.mat'),'cumulative','cfg');
                    historyTable=array2table(cumulative.history,'VariableNames', ...
                        {'Frame','CodedBER','DecodedBER','FrameErrorRate','Passed'});
                    writetable(historyTable,fullfile(summaryDir,'cumulative.csv'));
                    app.StatusLabel.Text=['累计结果已保存：' summaryDir]; drawnow;
                end
            catch ME
                caught=ME; app.LastError=ME.message;
                app.StatusLabel.Text=['本次未完成：' ME.message];
            end
            if isvalid(dialog), close(dialog); end
            app.Busy=false; app.setEnabled(true); app.StopButton.Enable='off'; app.updateMode(false);
            if ~isempty(caught)
                if strict, rethrow(caught); end
                uialert(app.UIFigure,caught.message,'本次实验未完成');
            end
        end
        function requestStop(app)
            if ~app.Busy, return; end
            app.StopRequested=true;
            app.StatusLabel.Text='已请求停止：收完当前帧后停止收发，再分析已完成的帧。';
        end
        function exportScreenshot(app,path)
            if nargin<2
                if isempty(app.LastResult), folder=app.RootDirectory; else, folder=app.LastResult.outputDirectory; end
                [name,folder]=uiputfile('*.png','保存当前展示页',fullfile(folder,'展示截图.png'));
                if isequal(name,0), return; end
                path=fullfile(folder,name);
            end
            drawnow; pause(0.3); drawnow; exportapp(app.UIFigure,path);
            app.StatusLabel.Text=['展示截图已保存：' char(path)];
        end
        function selectMode(app,value)
            app.ModeField.Value=char(value); app.updateMode();
        end
        function delete(app)
            if ~isempty(app.UIFigure) && isvalid(app.UIFigure), delete(app.UIFigure); end
        end
    end
    methods (Access=private)
        function createComponents(app,visible)
            navy=[0.065 0.12 0.21]; teal=[0.0 0.46 0.49]; bg=[0.94 0.955 0.975];
            app.UIFigure=uifigure('Name','JT65 通信实验展示台','Position',[30 35 1440 800], ...
                'Color',bg,'Visible',visible,'CloseRequestFcn',@(~,~)app.requestClose());
            root=uigridlayout(app.UIFigure,[3 2],'RowHeight',{72,'1x',25}, ...
                'ColumnWidth',{290,'1x'},'Padding',[16 12 16 10],'RowSpacing',12,'ColumnSpacing',14);
            root.BackgroundColor=bg;
            header=uipanel(root,'BackgroundColor',navy,'BorderType','none');
            header.Layout.Row=1; header.Layout.Column=[1 2];
            hg=uigridlayout(header,[2 2],'ColumnWidth',{'1x',260},'RowHeight',{34,22},'Padding',[20 6 20 6]);
            hg.BackgroundColor=navy;
            uilabel(hg,'Text','JT65 通信实验展示台','FontSize',25,'FontWeight','bold','FontColor',[1 1 1]);
            uilabel(hg,'Text','实验三  ·  实验四','FontSize',16,'FontColor',[0.65 0.89 0.91],'HorizontalAlignment','right');
            uilabel(hg,'Text','信号生成  /  同步检测  /  最大似然解调  /  RS 纠错','FontSize',12,'FontColor',[0.75 0.81 0.88]);
            app.TimingLabel=uilabel(hg,'Text','快速 · 正文 2.52 s · 每帧 7 bit','FontSize',12,'FontColor',[0.75 0.81 0.88],'HorizontalAlignment','right');
            side=uipanel(root,'BorderType','none','BackgroundColor',[1 1 1]); side.Layout.Row=2; side.Layout.Column=1;
            heights={20,30,26,26,16,30,16,30,18,26,22,26,34,16,16,26,18,46,46,24,34,26};
            g=uigridlayout(side,[numel(heights) 1],'RowHeight',heights,'RowSpacing',3,'Padding',[14 10 14 10]);
            g.BackgroundColor=[1 1 1];
            uilabel(g,'Text','实验控制','FontSize',17,'FontWeight','bold','FontColor',navy);
            modeGrid=uigridlayout(g,[1 2],'ColumnWidth',{'1x','1x'},'Padding',[0 0 0 0],'ColumnSpacing',5);
            modeGrid.BackgroundColor=[1 1 1];
            app.ModeField=uidropdown(modeGrid,'Items',{'仿真演示','录波回放','USRP 真机收发'}, ...
                'ValueChangedFcn',@(~,~)app.updateMode());
            app.SpeedModeField=uidropdown(modeGrid,'Items',{'快速 · 2.52 s','慢速 · 46.8 s'}, ...
                'ItemsData',{'fast','slow'},'Value','fast','FontSize',11, ...
                'Tooltip','正文时长；两种模式的 USRP 硬件采样率均为 204.8 kS/s。慢速用于弱信号对照，尚未证明 −20 dB 性能。', ...
                'ValueChangedFcn',@(~,~)app.applyLoopPreset());
            app.DecoderModeField=uidropdown(g,'Items',{'译码：128 候选整帧联合','译码：原 RS 硬判决'}, ...
                'ItemsData',{'joint7','hard'},'Value','joint7','FontSize',12, ...
                'Tooltip','搜索全部 0–127，不使用发送文字；证据不足或候选接近时未恢复。旧 72 bit 录波自动使用原 RS。', ...
                'ValueChangedFcn',@(~,~)app.markChanged());
            app.DetectionModeField=uidropdown(g,'Items',{'解调：非相干（原实现）','解调：相干（新增，约 +1.2 dB）'}, ...
                'ItemsData',{'noncoherent','coherent'},'Value','noncoherent','FontSize',12, ...
                'Tooltip','非相干为原有行为。相干利用 JT65 相位连续 FSK 的确定相位做判决，实测 50% 门限改善约 1.2 dB；估计出错时自动回退到非相干判决，不会比原实现差。', ...
                'ValueChangedFcn',@(~,~)app.markChanged());
            uilabel(g,'Text','发送内容 · ASCII 文字或 7 位二进制','FontColor',[0.32 0.38 0.46]);
            app.MessageField=uieditfield(g,'text','Value','hello','FontSize',16, ...
                'ValueChangedFcn',@(~,~)app.markChanged());
            uilabel(g,'Text','录波目录','FontColor',[0.32 0.38 0.46]);
            browse=uigridlayout(g,[1 2],'ColumnWidth',{'1x',52},'Padding',[0 0 0 0],'ColumnSpacing',5);
            browse.BackgroundColor=[1 1 1];
            app.SourceField=uieditfield(browse,'text','Value',app.latestCapture(),'ValueChangedFcn',@(~,~)app.updateMode());
            app.SourceButton=uibutton(browse,'Text','选择','ButtonPushedFcn',@(~,~)app.browseSource());
            uilabel(g,'Text','SNR 参考带宽','FontSize',14,'FontWeight','bold','FontColor',teal);
            app.BandwidthField=uidropdown(g,'Items',{'2500 Hz · JT65 常用口径','400 Hz · 参考口径','10000 Hz · 10 kHz 参考口径','20000 Hz · 20 kHz 等效口径'}, ...
                'ItemsData',[2500 400 10000 20000],'Value',2500,'ValueChangedFcn',@(~,~)app.markChanged());
            app.BandwidthField.Tooltip='按同一帧的带外噪声谱密度折算 SNR；信号与估噪频带随采样率缩放。不需要加噪，不改变实际解调带宽。';
            app.NoiseCheck=uicheckbox(g,'Text','可选：加入白噪声演示','Value',false,'ValueChangedFcn',@(~,~)app.noiseChanged());
            ng=uigridlayout(g,[1 3],'ColumnWidth',{64,72,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',5);
            ng.BackgroundColor=[1 1 1];
            uilabel(ng,'Text','SNR / dB');
            app.SnrField=uieditfield(ng,'numeric','Limits',[-30 10],'Value',-10, ...
                'ValueChangedFcn',@(~,~)app.changeSnr(app.SnrField.Value));
            app.NoiseButton=uibutton(ng,'Text','换组噪声','ButtonPushedFcn',@(~,~)app.nextNoise());
            app.SnrSlider=uislider(g,'Limits',[-30 10],'Value',-10,'MajorTicks',[-30 -20 -10 0 10], ...
                'MinorTicks',[],'ValueChangedFcn',@(~,~)app.changeSnr(app.SnrSlider.Value));
            uilabel(g,'Text','参考带宽独立可选；不勾选加噪即用原始数据。','WordWrap','on','FontSize',10,'FontColor',[0.43 0.48 0.55]);
            uilabel(g,'Text','仿真频偏 / Hz','FontColor',[0.32 0.38 0.46]);
            app.OffsetField=uieditfield(g,'numeric','Limits',[-15 15],'Value',2.5,'ValueChangedFcn',@(~,~)app.markChanged());
            uilabel(g,'Text','USRP 参数','FontSize',14,'FontWeight','bold','FontColor',teal);
            rg=uigridlayout(g,[2 2],'RowHeight',{16,28},'ColumnWidth',{'1x','1x'},'Padding',[0 0 0 0],'RowSpacing',3);
            rg.BackgroundColor=[1 1 1];
            uilabel(rg,'Text','中心频率 / MHz','FontSize',11); uilabel(rg,'Text','设备序列号','FontSize',11);
            app.CenterField=uieditfield(rg,'numeric','Value',435,'Limits',[70 6000],'ValueChangedFcn',@(~,~)app.markChanged());
            app.SerialField=uieditfield(rg,'text','Placeholder','自动识别','ValueChangedFcn',@(~,~)app.markChanged());
            gg=uigridlayout(g,[2 2],'RowHeight',{16,28},'ColumnWidth',{'1x','1x'},'Padding',[0 0 0 0],'RowSpacing',3);
            gg.BackgroundColor=[1 1 1];
            uilabel(gg,'Text','TX 增益 / dB','FontSize',11); uilabel(gg,'Text','RX 增益 / dB','FontSize',11);
            app.TxGainField=uieditfield(gg,'numeric','Value',30,'Limits',[0 89.75],'ValueChangedFcn',@(~,~)app.markChanged());
            app.RxGainField=uieditfield(gg,'numeric','Value',40,'Limits',[0 76],'ValueChangedFcn',@(~,~)app.markChanged());
            loopGrid=uigridlayout(g,[1 3],'ColumnWidth',{54,'1x',54},'ColumnSpacing',5,'Padding',[0 0 0 0]);
            loopGrid.BackgroundColor=[1 1 1];
            app.LoopCheck=uicheckbox(loopGrid,'Text','循环','Value',true,'ValueChangedFcn',@(~,~)app.updateMode(false));
            app.LoopPresetField=uidropdown(loopGrid,'Items',{'约 1 分钟','至少 1000 比特','自定义次数'}, ...
                'ItemsData',{'minute','bits1000','custom'},'Value','minute','FontSize',11, ...
                'Tooltip','约 1 分钟：20 次 / 140 bit / 58.4 s；至少 1000 比特：143 次 / 1001 bit / 417.56 s。', ...
                'ValueChangedFcn',@(~,~)app.applyLoopPreset());
            app.FrameCountField=uieditfield(loopGrid,'numeric','Value',20,'Limits',[0 10000], ...
                'RoundFractionalValues','on','Tooltip','默认 20 帧约 58.4 秒，共 140 个有效比特；0 表示持续循环，直到请求停止。','ValueChangedFcn',@(~,~)app.frameCountChanged());
            runGrid=uigridlayout(g,[1 2],'ColumnWidth',{'1x',70},'Padding',[0 0 0 0],'ColumnSpacing',6);
            runGrid.BackgroundColor=[1 1 1];
            app.RunButton=uibutton(runGrid,'Text','运行仿真','FontSize',15,'FontWeight','bold', ...
                'BackgroundColor',teal,'FontColor',[1 1 1],'ButtonPushedFcn',@(~,~)app.runExperiment());
            app.StopButton=uibutton(runGrid,'Text','停止','Enable','off','ButtonPushedFcn',@(~,~)app.requestStop());
            app.ExportButton=uibutton(g,'Text','保存当前展示页','ButtonPushedFcn',@(~,~)app.exportScreenshot());
            main=uigridlayout(root,[3 1],'RowHeight',{83,'1x',49},'Padding',[0 0 0 0],'RowSpacing',12);
            main.Layout.Row=2; main.Layout.Column=2;
            main.BackgroundColor=bg;
            cards=uigridlayout(main,[1 4],'Padding',[0 0 0 0],'ColumnSpacing',10);
            cards.BackgroundColor=bg;
            app.CardValues=cell(1,4); app.CardTitles=cell(1,4);
            titles={'SNR','帧起点 / s','估计频偏 / Hz','译码后 BER'};
            for k=1:4
                p=uipanel(cards,'BorderType','none','BackgroundColor',[1 1 1]);
                cg=uigridlayout(p,[2 1],'RowHeight',{22,'1x'},'Padding',[15 8 10 8],'RowSpacing',0);
                cg.BackgroundColor=[1 1 1];
                app.CardTitles{k}=uilabel(cg,'Text',titles{k},'FontSize',11,'FontColor',[0.4 0.45 0.52]);
                app.CardValues{k}=uilabel(cg,'Text','—','FontSize',25,'FontWeight','bold','FontColor',navy);
            end
            app.Tabs=uitabgroup(main);
            names={'收发总览','时间与频率同步','解调与纠错','累计统计'};
            app.Axes=cell(4,4);
            for row=1:4
                tab=uitab(app.Tabs,'Title',names{row},'BackgroundColor',[1 1 1]);
                ag=uigridlayout(tab,[2 2],'Padding',[12 14 12 8],'ColumnSpacing',18,'RowSpacing',18);
                ag.BackgroundColor=[1 1 1];
                for col=1:4
                    ax=uiaxes(ag,'FontSize',10,'Box','on','XGrid','on','YGrid','on');
                    ax.Toolbar.Visible='off'; app.Axes{row,col}=ax;
                end
            end
            footer=uipanel(main,'BorderType','none','BackgroundColor',[0.88 0.94 0.94]);
            fg=uigridlayout(footer,[1 1],'Padding',[15 5 15 5]);
            fg.BackgroundColor=[0.88 0.94 0.94];
            app.ResultLabel=uilabel(fg,'Text','准备就绪','FontSize',14,'FontColor',navy,'WordWrap','on');
            app.StatusLabel=uilabel(root,'Text','准备就绪','FontSize',11,'FontColor',[0.4 0.45 0.52]);
            app.StatusLabel.Layout.Row=3; app.StatusLabel.Layout.Column=[1 2];
            app.Controls={app.ModeField,app.SpeedModeField,app.DecoderModeField,app.DetectionModeField,app.MessageField,app.SourceField,app.SourceButton, ...
                app.NoiseCheck,app.BandwidthField,app.SnrField,app.SnrSlider,app.NoiseButton,app.OffsetField, ...
                app.CenterField,app.SerialField,app.TxGainField,app.RxGainField,app.LoopCheck,app.LoopPresetField,app.FrameCountField,app.RunButton,app.ExportButton};
        end
        function cfg=readConfig(app)
            cfg=struct('Mode',string(app.ModeField.Value),'SpeedMode',app.SpeedModeField.Value,'Message',app.MessageField.Value, ...
                'DecoderMode',app.DecoderModeField.Value, ...
                'DetectionMode',app.DetectionModeField.Value, ...
                'SourceDirectory',app.SourceField.Value,'AddNoise',app.NoiseCheck.Value, ...
                'Bandwidth',app.BandwidthField.Value,'SnrDb',app.SnrField.Value, ...
                'FrequencyOffset',app.OffsetField.Value,'CenterMHz',app.CenterField.Value, ...
                'Serial',app.SerialField.Value,'TxGain',app.TxGainField.Value, ...
                'RxGain',app.RxGainField.Value,'Seed',app.NoiseSeed,'LoopPreset',app.LoopPresetField.Value,'FrameCount',1);
            if app.LoopCheck.Value && cfg.Mode=="USRP 真机收发", cfg.FrameCount=app.FrameCountField.Value; end
        end
        function applyLoopPreset(app)
            switch app.LoopPresetField.Value
                case 'minute'
                    T=jt65_timing(string(app.SpeedModeField.Value)); app.FrameCountField.Value=T.minuteFrames;
                case 'bits1000', app.FrameCountField.Value=143;
            end
            app.markChanged();
        end
        function frameCountChanged(app)
            T=jt65_timing(string(app.SpeedModeField.Value));
            if app.FrameCountField.Value==T.minuteFrames, app.LoopPresetField.Value='minute';
            elseif app.FrameCountField.Value==143, app.LoopPresetField.Value='bits1000';
            else, app.LoopPresetField.Value='custom';
            end
            app.markChanged();
        end
        function updateMode(app,resetNoise)
            if nargin<2, resetNoise=true; end
            mode=string(app.ModeField.Value);
            app.SpeedModeField.Enable=matlab.lang.OnOffSwitchState(mode~="录波回放");
            app.MessageField.Enable=matlab.lang.OnOffSwitchState(mode~="录波回放");
            app.SourceField.Enable=matlab.lang.OnOffSwitchState(mode=="录波回放");
            app.SourceButton.Enable=app.SourceField.Enable;
            app.OffsetField.Enable=matlab.lang.OnOffSwitchState(mode=="仿真演示");
            radio={app.CenterField,app.SerialField,app.TxGainField,app.RxGainField};
            for k=1:numel(radio), radio{k}.Enable=matlab.lang.OnOffSwitchState(mode=="USRP 真机收发"); end
            app.LoopCheck.Enable=matlab.lang.OnOffSwitchState(mode=="USRP 真机收发");
            app.FrameCountField.Enable=matlab.lang.OnOffSwitchState(mode=="USRP 真机收发" && app.LoopCheck.Value);
            app.LoopPresetField.Enable=app.FrameCountField.Enable;
            if resetNoise, app.NoiseCheck.Value=false; end
            noiseControls={app.SnrField,app.SnrSlider,app.NoiseButton};
            for k=1:numel(noiseControls)
                noiseControls{k}.Enable=matlab.lang.OnOffSwitchState(app.NoiseCheck.Value);
            end
            if mode=="仿真演示", app.RunButton.Text='运行仿真';
            elseif mode=="USRP 真机收发"
                if app.LoopCheck.Value, app.RunButton.Text='开始循环收发'; else, app.RunButton.Text='开始一帧收发'; end
            else
                app.RunButton.Text='分析录波';
                path=fullfile(app.SourceField.Value,'tx_reference.mat');
                if isfile(path)
                    ref=load(path);
                    if ref.fs==11025, app.SpeedModeField.Value='slow'; else, app.SpeedModeField.Value='fast'; end
                    if strcmp(app.LoopPresetField.Value,'minute')
                        T=jt65_timing(string(app.SpeedModeField.Value)); app.FrameCountField.Value=T.minuteFrames;
                    end
                    if isfield(ref,'sourceMessage'), app.MessageField.Value=char(ref.sourceMessage);
                    else, app.MessageField.Value=char(ref.userMsg); end
                end
            end
            app.updateTiming();
            app.SourceField.Tooltip=app.SourceField.Value;
            if resetNoise, app.markChanged(); end
        end
        function noiseChanged(app)
            app.updateMode(false); app.markChanged();
        end
        function changeSnr(app,value)
            value=round(value*10)/10;
            app.SnrField.Value=value; app.SnrSlider.Value=value; app.markChanged();
        end
        function nextNoise(app)
            if app.Busy, return; end
            app.NoiseSeed=app.NoiseSeed+1; app.markChanged();
        end
        function updateTiming(app)
            T=jt65_timing(string(app.SpeedModeField.Value));
            app.TimingLabel.Text=sprintf('%s · 正文 %.2f s · 每帧 7 bit',T.label,T.payloadSeconds);
            app.LoopPresetField.Tooltip=sprintf('约 1 分钟：%d 次 / %d bit / %.2f 秒；至少 1000 比特：143 次 / 1001 bit / %.1f 分钟。', ...
                T.minuteFrames,7*T.minuteFrames,T.minuteFrames*T.frameSeconds,143*T.frameSeconds/60);
            n=app.FrameCountField.Value;
            if ~app.LoopCheck.Value, n=1; end
            if n==0
                plan=sprintf('%s：每帧 %.2f 秒；持续循环，收完当前帧后停止。',T.label,T.frameSeconds);
            else
                plan=sprintf('%s：%d 帧 / %d bit；收发 %.2f 秒（%.1f 分钟），分析时间另计。',T.label,n,7*n,n*T.frameSeconds,n*T.frameSeconds/60);
            end
            app.FrameCountField.Tooltip=plan; app.RunButton.Tooltip=plan;
        end
        function markChanged(app)
            app.updateTiming();
            if isempty(app.LastResult)
                app.StatusLabel.Text=['选择模式和参数，点击运行。' app.RunButton.Tooltip];
            else
                app.StatusLabel.Text=['参数已修改；当前图表仍对应上一次运行。' app.RunButton.Tooltip];
            end
        end
        function browseSource(app)
            folder=uigetdir(fullfile(app.RootDirectory,'data'),'选择一次采集目录');
            if isequal(folder,0), return; end
            app.SourceField.Value=folder; app.updateMode();
        end
        function folder=latestCapture(app)
            entries=dir(fullfile(app.RootDirectory,'data','jt65_live_*','rx_capture.mat'));
            if isempty(entries), folder=fullfile(app.RootDirectory,'data'); return; end
            [~,i]=max([entries.datenum]); folder=entries(i).folder;
        end
        function setEnabled(app,value)
            for k=1:numel(app.Controls)
                app.Controls{k}.Enable=matlab.lang.OnOffSwitchState(value);
            end
        end
        function requestClose(app)
            if app.Busy
                app.requestStop();
                uialert(app.UIFigure,'已请求收完当前帧后停止。分析完成后可关闭窗口。','停止采集');
            else
                delete(app);
            end
        end
        function renderResult(app,P)
            S=P.S; R=P.result; fs=P.fs; speedScale=fs/11025;
            for k=1:numel(app.Axes)
                colorbar(app.Axes{k},'off'); cla(app.Axes{k},'reset');
                app.Axes{k}.FontSize=10; app.Axes{k}.Toolbar.Visible='off';
                grid(app.Axes{k},'on'); box(app.Axes{k},'on');
            end
            ax=app.Axes{1,1}; count=ceil(11025*0.01);
            plot(ax,(0:count-1)/fs*1000,real(S.wave(1:count)),'LineWidth',1); hold(ax,'on');
            plot(ax,(0:count-1)/fs*1000,imag(S.wave(1:count)),'LineWidth',1);
            legend(ax,{'I','Q'},'Location','northeast');
            app.labelAxes(ax,sprintf('发送时域 · 前 %.2f ms',count/fs*1000),'时间 / ms','归一化幅度');
            ax=app.Axes{1,2}; stairs(ax,(0:S.nSlot-1)*S.nSamp/fs,S.freq,'LineWidth',1.1);
            xlim(ax,[0 numel(S.wave)/fs]);
            app.labelAxes(ax,'发送频率 · 同步音与数据音','帧内时间 / s','基带频率 / Hz');
            ax=app.Axes{1,3};
            [power,f]=pwelch(S.wave,hann(4096,'periodic'),2048,16384,fs,'centered');
            keep=f>=1150*speedScale & f<=1550*speedScale;
            plot(ax,f(keep),10*log10(power(keep)/max(power)+eps),'LineWidth',1.2);
            xlim(ax,[1150 1550]*speedScale); ylim(ax,[-70 5]);
            app.labelAxes(ax,'发送频谱','基带频率 / Hz','归一化功率谱 / dB');
            ax=app.Axes{1,4};
            [~,f,t,p]=spectrogram(P.rx,4096,3072,8192,fs,'centered');
            keep=f>=1150*speedScale & f<=1550*speedScale;
            waterfallDb=10*log10(p(keep,:)+realmin);
            imagesc(ax,t,f(keep),waterfallDb); axis(ax,'xy');
            peakDb=max(waterfallDb,[],'all'); clim(ax,[peakDb-65 peakDb]);
            colormap(ax,parula); c=colorbar(ax); c.Label.String='dBFS/Hz';
            app.labelAxes(ax,'接收瀑布图','采集时间 / s','基带频率 / Hz');
            if P.config.AddNoise
                app.CardTitles{1}.Text=sprintf('目标 SNR / %d Hz',P.config.Bandwidth);
                app.CardValues{1}.Text=sprintf('%.1f dB',P.config.SnrDb);
            elseif P.config.Mode=="仿真演示"
                app.CardTitles{1}.Text='理想仿真'; app.CardValues{1}.Text='未加噪';
            elseif ~isempty(R)
                app.CardTitles{1}.Text=sprintf('估计 SNR / %d Hz',P.config.Bandwidth);
                if P.referenceIsEquivalent, app.CardTitles{1}.Text=sprintf('等效 SNR / %g kHz',P.config.Bandwidth/1000); end
                app.CardValues{1}.Text=sprintf('%.1f dB',P.referenceSnrDb);
            else
                app.CardTitles{1}.Text='SNR'; app.CardValues{1}.Text='未估计';
            end
            if isempty(R)
                app.CardValues{2}.Text='未同步'; app.CardValues{3}.Text='—'; app.CardValues{4}.Text='未解码';
                for row=2:3
                    for col=1:4
                        ax=app.Axes{row,col}; axis(ax,'off');
                        text(ax,0.5,0.55,'未检出可靠同步','Units','normalized','HorizontalAlignment','center','FontSize',16,'Color',[0.7 0.3 0.15]);
                        text(ax,0.5,0.42,'提高 SNR 后重新运行；本帧未计为零误码。','Units','normalized','HorizontalAlignment','center','FontSize',10);
                    end
                end
                app.ResultLabel.Text=['未同步  |  ' P.failure]; app.ResultLabel.FontColor=[0.7 0.28 0.12];
                return;
            end
            app.CardValues{2}.Text=sprintf('%.3f',R.frameStartSeconds);
            app.CardValues{3}.Text=sprintf('%+.2f',R.frequencyOffset);
            if R.decoderAccepted, app.CardValues{4}.Text=sprintf('%.4f',R.ber);
            else, app.CardValues{4}.Text='译码失败'; end
            D=R.diagnostics; Q=R.snr;
            ax=app.Axes{2,1}; plot(ax,D.timeSeconds,D.timeScores,'LineWidth',1.3); hold(ax,'on');
            plot(ax,R.frameStartSeconds,R.syncScore,'o','MarkerFaceColor',[0.9 0.35 0.13],'Color',[0.9 0.35 0.13]);
            app.labelAxes(ax,'时间同步 · 最佳候选（无门限）','候选起点 / s','同步得分');
            ax=app.Axes{2,2}; plot(ax,D.frequencyOffsetHz,D.frequencyBeforeDb,'LineWidth',1.2); hold(ax,'on');
            plot(ax,D.frequencyOffsetHz,D.frequencyAfterDb,'--','LineWidth',1.2);
            xline(ax,0,':','HandleVisibility','off');
            xlim(ax,[-1 1]*max(0.5,abs(R.frequencyOffset)+0.5)); ylim(ax,[-65 5]);
            legend(ax,{'校正前','校正后'},'Location','southwest');
            app.labelAxes(ax,'频率同步 · 偏移估计与补偿','相对同步音的偏移 / Hz','归一化幅度 / dB');
            ax=app.Axes{2,3};
            if isfield(D,'searchScoreMap')
                imagesc(ax,D.searchTimeSeconds,D.searchFrequencyOffsetsHz,D.searchScoreMap.'); axis(ax,'xy');
                colorbar(ax); colormap(ax,parula);
                app.labelAxes(ax,'联合搜索 · 时间 × 频偏','候选起点 / s','候选频偏 / Hz');
            else
                axis(ax,'off'); text(ax,0.1,0.5,'本次使用传统同步模式','Units','normalized');
            end
            ax=app.Axes{2,4};
            plot(ax,Q.frequencyHz,10*log10(Q.framePsd+realmin),'LineWidth',1.1); hold(ax,'on');
            plot(ax,Q.frequencyHz,10*log10(Q.noisePsd+realmin),'LineWidth',1.1);
            legend(ax,{'帧内信号 + 噪声','带外估计噪声密度'},'Location','northeast'); xlim(ax,Q.displayBandHz);
            xline(ax,Q.bandHz,':','HandleVisibility','off');
            app.labelAxes(ax,'接收频谱 · 信号带与带外噪声','基带频率 / Hz','功率谱密度 / dBFS/Hz');
            ax=app.Axes{3,1}; energy=D.mlEnergy./max(D.mlEnergy,[],1);
            imagesc(ax,1:63,0:63,10*log10(energy+realmin)); axis(ax,'xy'); clim(ax,[-35 0]); colormap(ax,parula);
            c=colorbar(ax); c.Label.String='相对最大能量 / dB';
            app.labelAxes(ax,'最大似然解调 · 64 个候选音','数据符号序号','候选符号');
            ax=app.Axes{3,2}; stem(ax,1:63,S.gray,'filled','MarkerSize',3); hold(ax,'on');
            stem(ax,1:63,R.symbols,'x','MarkerSize',4); legend(ax,{'发送','判决'},'Location','northeast');
            app.labelAxes(ax,sprintf('解调符号对比 · 错误 %d/63',R.symbolErrors),'数据符号序号','符号值');
            if strcmp(R.rsDiagnostics.mode,'joint7')
                d=R.rsDiagnostics; cla(ax); legend(ax,'off');
                plot(ax,0:127,d.candidateLogEvidence,'-','LineWidth',1.1); hold(ax,'on');
                plot(ax,d.bestValue,d.logEvidence,'o','MarkerFaceColor',[0 .46 .49]);
                yline(ax,d.logEvidenceThreshold,'--','证据门限','LabelHorizontalAlignment','left');
                xlim(ax,[-1 128]);
                state='未恢复'; if R.decoderAccepted, state=sprintf('输出 %s',dec2bin(d.bestValue,7)); end
                app.labelAxes(ax,['全部 128 候选 · ' state],'七比特数值（0–127）','对数证据');
            end
            ax=app.Axes{3,3};
            idx=R.payloadIndices;
            bits=[double(S.msgBits(idx).');double(R.decodedBits(idx).');double(R.decodedBits(idx).'~=S.msgBits(idx).')];
            imagesc(ax,1:R.payloadBitCount,1:3,bits); clim(ax,[0 1]); colormap(ax,[0.94 0.96 0.98;0.04 0.43 0.51]);
            yticks(ax,1:3); yticklabels(ax,{'发送比特','译码输出','错误位置'});
            app.labelAxes(ax,sprintf('有效比特核对 · 错误 %d/%d',R.bitErrors,R.payloadBitCount),'消息比特序号','');
            if ~R.decoderAccepted, title(ax,'候选比特 · 未恢复，不计入有效 BER'); end
            ax=app.Axes{3,4}; axis(ax,'off'); V=R.validation;
            demodLabel='非相干解调（原实现）';
            if isfield(R.diagnostics,'demodulator') && strcmp(R.diagnostics.demodulator.detectionMode,'coherent')
                dd=R.diagnostics.demodulator;
                demodLabel=sprintf('相干解调（τ残差 %.0f 抽样，相干度 %.3f）', ...
                    dd.timingOffsetSamples,dd.phaseCoherence);
            end
            lines={'解格雷映射  →  解交织  →  RS 译码', ...
                sprintf('逆格雷错误：%d/63；解交织错误：%d/63',V.inverseGraySymbolErrors,V.deinterleavedSymbolErrors), ...
                sprintf('RS(63,12)：378 bit → 72 bit · %s',demodLabel), ...
                sprintf('RS 纠正符号数：%d（-1 表示失败）',R.rsCorrectedSymbols), ...
                sprintf('发送：%s',S.userMsg),sprintf('收到：%s',strtrim(R.message))};
            decoderSummary=sprintf('RS 纠正 %d 个符号',R.rsCorrectedSymbols);
            if strcmp(R.rsDiagnostics.mode,'joint7')
                d=R.rsDiagnostics;
                lines{1}='全部 128 候选 → 整帧软能量 → 证据检验';
                lines{2}=sprintf('对数证据：%.1f / %.1f',d.logEvidence,d.logEvidenceThreshold);
                lines{3}=sprintf('对数优势：%.1f / %.1f',d.logOdds,d.logOddsThreshold);
                lines{4}='7 bit + 65 位补零；未限定发送文字';
                decoderSummary='128 候选整帧联合判决';
            end
            for k=1:numel(lines)
                text(ax,0.02,0.92-(k-1)*0.15,lines{k},'Units','normalized','FontSize',12,'Interpreter','none');
            end
            title(ax,'译码过程与消息','FontSize',12);
            source=char(P.config.Mode);
            if P.config.AddNoise && P.config.Mode~="仿真演示", source=[source ' + 软件加噪']; end
            if ~R.transportClean
                app.ResultLabel.Text=sprintf('%s  |  采集报告欠载、溢出或空读，本帧不能作为连续采样实验结果。',source);
                app.ResultLabel.FontColor=[0.7 0.28 0.12];
            elseif R.passed
                app.ResultLabel.Text=sprintf('%s  |  发送 "%s" → 收到 "%s"  |  %s  |  有效比特 0/%d 错误', ...
                    source,S.userMsg,strtrim(R.message),decoderSummary,R.payloadBitCount);
                app.ResultLabel.FontColor=[0 0.38 0.36];
            else
                app.ResultLabel.Text=sprintf('%s  |  本帧未通过：%s  |  解调符号错误 %d/63，有效比特错误 %d/%d', ...
                    source,strtrim(R.message),R.symbolErrors,R.bitErrors,R.payloadBitCount);
                app.ResultLabel.FontColor=[0.7 0.28 0.12];
            end
        end
        function captureProgress(app,dialog,index,seconds,total)
            content=app.MessageField.Value;
            if ~(numel(content)==7 && all(ismember(content,'01')))
                content=content(mod(index-1,numel(content))+1);
            end
            message=sprintf('连续采集：第 %d 帧，发送 "%s"，%.1f / %.1f 秒；采完后统一分析。',index,content,seconds,total);
            if app.StopRequested || dialog.CancelRequested
                message=[message ' 当前帧结束后停止。'];
            end
            app.StatusLabel.Text=message; dialog.Message=message;
            drawnow limitrate;
        end
        function renderCumulative(app)
            A=app.Cumulative; H=A.history;
            app.CardTitles{4}.Text='累计 BER / 已译码比特';
            if A.decodedBits>0, app.CardValues{4}.Text=sprintf('%.4g',A.decodedBer);
            else, app.CardValues{4}.Text='无有效输出'; end
            app.CardValues{4}.Tooltip=sprintf('%d / %d bit；另有 %d bit 未恢复，失败帧 %d/%d。', ...
                A.decodedErrors,A.decodedBits,A.unknownMessageBits,A.failedFrames,A.frames);
            ax=app.Axes{4,1}; plot(ax,H(:,1),H(:,2),'-o',H(:,1),H(:,3),'-s','LineWidth',1.2);
            legend(ax,{'译码前 BER','成功译码帧 BER'},'Location','best'); ylim(ax,[0 1]);
            app.labelAxes(ax,'累计比特错误率','已处理帧数','BER');
            ax=app.Axes{4,2}; plot(ax,H(:,1),100*H(:,4),'-o','LineWidth',1.2); ylim(ax,[0 100]);
            app.labelAxes(ax,'累计失败帧比例 · 含未译码及采集异常','已处理帧数','失败帧 / %');
            ax=app.Axes{4,3}; bar(ax,[A.passedFrames,A.failedFrames]);
            xticks(ax,[1 2]); xticklabels(ax,{'正确帧','失败帧'});
            app.labelAxes(ax,'整帧统计','','帧数');
            ax=app.Axes{4,4}; axis(ax,'off');
            lines={sprintf('累计 %d 帧 / %d 有效 bit；正确 %d；失败 %d',A.frames,A.payloadBitsSent,A.passedFrames,A.failedFrames), ...
                sprintf('译码前：%d / %d bit 错误',A.codedErrors,A.codedBits), ...
                sprintf('成功译码帧：%d / %d bit 错误',A.decodedErrors,A.decodedBits), ...
                sprintf('未恢复 %d bit；采集异常 %d 帧',A.unknownMessageBits,A.transportFailedFrames), ...
                sprintf('计入未知比特的 BER 范围：[%.4g, %.4g]',A.messageBerBounds), ...
                '失败帧没有计为零误码；单次零错误不等于长期 BER 为零。'};
            for k=1:numel(lines), text(ax,0.02,0.93-(k-1)*0.15,lines{k},'Units','normalized','FontSize',11,'Interpreter','none'); end
            title(ax,'分母与失败帧说明');
            if ~isempty(A.receivedText)
                shown=A.receivedText(max(1,end-47):end);
                app.ResultLabel.Text=sprintf('累计收到：%s  |  每帧 7 bit',shown);
                app.ResultLabel.Tooltip=sprintf('发送：%s\n收到：%s\n? 表示该帧没有可靠输出。',A.sentText,A.receivedText);
            else
                app.ResultLabel.Tooltip='';
            end
            app.ResultLabel.Text=sprintf('%s  |  累计 %d 帧 / %d bit；失败 %d 帧；未恢复 %d bit', ...
                app.ResultLabel.Text,A.frames,A.payloadBitsSent,A.failedFrames,A.unknownMessageBits);
        end
        function labelAxes(~,ax,heading,x,y)
            title(ax,heading,'FontSize',12,'FontWeight','bold','Interpreter','none');
            xlabel(ax,x); ylabel(ax,y);
        end
    end
end
