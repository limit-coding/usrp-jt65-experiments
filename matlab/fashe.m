%USRP 发射信号代码
Device_USRP = findsdru;%获取连接设备
if strncmp(Device_USRP(1).Status,'Success',7)
    disp('Connect Successful !');
    SYS.Platform = Device_USRP.Platform;
    switch SYS.Platform
        case {'B200','B210'}
            SYS.Address = Device_USRP.SerialNum;
        case {'N200/N210/USRP2','X300','X310'}
            SYS.Address = Device_USRP.IPAddress;
    end

    %% USRP transmitter parameters for B210
    SYS.MasterClockRate         = 61.44e6;
    SYS.USRPCenterFrequency     = 4e9;%5.5GHZ
    SYS.USRPGain                = 70;
    SYS.USRPFrontEndSampleRate  = fs;  % 采样率
    SYS.USRPInterpolationFactor = floor(SYS.MasterClockRate/SYS.USRPFrontEndSampleRate);

    radio = comm.SDRuTransmitter(...
        'Platform',             SYS.Platform, ...
        'SerialNum',            SYS.Address, ...
        'MasterClockRate',      SYS.MasterClockRate, ...
        'CenterFrequency',      SYS.USRPCenterFrequency, ...
        'Gain',                 SYS.USRPGain, ...
        'InterpolationFactor',  SYS.USRPInterpolationFactor, ...
        'LocalOscillatorOffset',5e6);
    radio.ChannelMapping = 1 ;     % Use both TX channels
    radio.UnderrunOutputPort = true;

    underrun = step(radio, Tx_msg);%发送信号
end