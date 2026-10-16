function Q=jt65_pilot_snr(rx,S,startSeconds,cfo)
% 从公开同步时隙估计单音信号与邻近噪声；无需已知发送文本。
% 2500 Hz 数值按局部噪声谱密度折算，假设噪声在参考带宽内近似平坦。
% 仅在成功同步后调用。区间为独立、平稳复高斯噪声近似，非仪器校准值。
L=S.nSamp; fs=S.fs; syncSlots=find(S.sync==1);
indices=round(startSeconds*fs)+(syncSlots(:).'-1)*L+(1:L).';
x=rx(indices).*exp(-2i*pi*(S.fSync+cfo)*(indices-1)/fs);
z=fft(x,[],1)/L;
noiseBins=mod([-40:-4 4:40],L)+1;
noiseE=abs(z(noiseBins,:)).^2;
noisePower=median(noiseE(:))/log(2);
pilotTotal=mean(abs(z(1,:)).^2);
signalPower=pilotTotal-noisePower;
Q=struct('referenceBandwidthHz',2500,'binBandwidthHz',fs/L, ...
    'signalPower',signalPower,'noisePerBin',noisePower,'snr2500Db',NaN, ...
    'snr400Db',NaN,'snr2500IntervalDb',[NaN NaN], ...
    'assumption','同步音与数据音等功率；局部噪声密度平坦；独立平稳复高斯噪声近似');
if signalPower<=0 || noisePower<=0, return; end
ratio=signalPower/noisePower;
Q.snr2500Db=10*log10(ratio*(fs/L)/2500);
Q.snr400Db=10*log10(ratio*(fs/L)/400);
% 同步音功率均值方差与中位数估噪方差的一阶传播。
ratioSE=sqrt((1+2*ratio)/numel(syncSlots)+(ratio+1)^2/(numel(noiseE)*log(2)^2));
ci=max(0,ratio+[-1 1]*1.96*ratioSE);
Q.snr2500IntervalDb=10*log10(ci*(fs/L)/2500);
end
