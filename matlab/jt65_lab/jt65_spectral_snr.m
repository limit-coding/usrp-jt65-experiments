function Q=jt65_spectral_snr(rx,S,startSeconds,cfo)
% 同一帧频域估噪：以下基准频带按 S.fs/11025 等比例缩放。
% 基准信号带 [1255,1465]、噪声区 [1000,1230;1490,1720] Hz。
% 用两侧平均噪声谱密度代表信号带内噪声；所有参考带宽均按此密度折算。
fs=S.fs; scale=fs/11025;
signalBand=[1255 1465]*scale; noiseBands=[1000 1230;1490 1720]*scale;
indices=round(startSeconds*fs)+(1:S.nSlot*S.nSamp);
frame=rx(indices); frame=frame(:).*exp(-2i*pi*cfo*(0:numel(indices)-1).'/fs);
[psd,f]=pwelch(frame,hann(4096,'periodic'),2048,16384,fs,'centered');
pTotal=integrate(psd,f,signalBand);
sidePower=[integrate(psd,f,noiseBands(1,:));integrate(psd,f,noiseBands(2,:))];
widths=diff(noiseBands,1,2); n0=sum(sidePower)/sum(widths);
pNoise=n0*diff(signalBand); pSignal=pTotal-pNoise;
Q=struct('method','same-frame out-of-band PSD','bandHz',signalBand, ...
    'bandwidthHz',diff(signalBand),'bandDb',NaN,'signalBandDb',NaN,'fullBandDb',NaN, ...
    'signalDbFS',NaN,'noiseDbFS',10*log10(n0*400),'totalDbFS',10*log10(pTotal), ...
    'noiseSeconds',numel(frame)/fs,'noiseDriftDb',NaN, ...
    'signalPower',pSignal,'signalBandTotalPower',pTotal,'signalBandNoisePower',pNoise, ...
    'noiseDensity',n0,'noiseDensityDbFSPerHz',10*log10(n0), ...
    'noiseBandsHz',noiseBands,'noiseEstimationBandwidthHz',sum(widths), ...
    'noiseSideDifferenceDb',10*log10((sidePower(1)/widths(1))/(sidePower(2)/widths(2))), ...
    'referenceBandwidthsHz',[400 2500 10000 20000],'referenceSnrDb',nan(1,4), ...
    'assumption','两侧噪声代表信号带内噪声；参考带宽按平坦噪声密度折算');
if pSignal>0 && n0>0
    Q.signalDbFS=10*log10(pSignal);
    Q.referenceSnrDb=10*log10(pSignal./(n0*Q.referenceBandwidthsHz));
    Q.bandDb=Q.referenceSnrDb(1); % 保留历史 400 Hz 参考字段，信号积分带已独立。
    Q.signalBandDb=10*log10(pSignal/pNoise);
    Q.fullBandDb=10*log10(pSignal/(n0*fs));
end
keep=f>=950*scale & f<=1770*scale;
Q.frequencyHz=f(keep); Q.framePsd=psd(keep); Q.noisePsd=ones(nnz(keep),1)*n0;
Q.displayBandHz=[950 1770]*scale;
end

function p=integrate(psd,f,band)
fb=[band(1);f(f>band(1) & f<band(2));band(2)];
p=trapz(fb,interp1(f,psd,fb));
end
