%USRP 接受信号代码
Device_USRP = findsdru;%链接设备
if strncmp(Device_USRP(1).Status, 'Success', 7)
    radioFound = true;
    platform = Device_USRP(1).Platform;
    switch Device_USRP(1).Platform
        case {'B200','B210'}
            address = Device_USRP.SerialNum;
        case {'N200/N210/USRP2','X300','X310'}
            address = Device_USRP(1).IPAddress;
    end
    SYS.Platform = platform;
    SYS.Address  = address;
    % USRP Receiver parameters for B210
    SYS.MasterClockRate        = 61.44e6;% Hz
    SYS.USRPCenterFrequency    = 4e9;%2260,-2930，误码是这里频偏影响？
    SYS.USRPGain               = 70;
    SYS.USRPFrontEndSampleRate = fs;
    SYS.USRPDecimationFactor   = 100;
    SYS.USRPFrameLength        = 4096*126*2;%传输脉冲+脉冲间隔,接收两帧

    radio = comm.SDRuReceiver(...
        'Platform',             SYS.Platform, ...
        'SerialNum',            SYS.Address, ...
        'MasterClockRate',      SYS.MasterClockRate, ...
        'CenterFrequency',      SYS.USRPCenterFrequency, ...
        'Gain',                 SYS.USRPGain, ...
        'DecimationFactor',     SYS.USRPDecimationFactor, ...
        'SamplesPerFrame',      SYS.USRPFrameLength, ...
        'OutputDataType',       'double', ...
        'LocalOscillatorOffset',5e6);
    radio.EnableBurstMode = 1;
    radio.NumFramesInBurst = 1;
end

hlog = dsp.SignalSink;%创建接收器对象
rcvdSignal = radio();
hlog(rcvdSignal);
signal_receive= hlog.Buffer;