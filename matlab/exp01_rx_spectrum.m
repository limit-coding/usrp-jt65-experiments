% Capture IQ from B210 and draw a baseband spectrum.
clear; clc;
serialNum = '347380A'; centerFrequency = 100.6e6; sampleRate = 1e6;
seconds = 5; samplesPerFrame = 20000; nFrames = ceil(seconds*sampleRate/samplesPerFrame);
rx = comm.SDRuReceiver('Platform','B210','SerialNum',serialNum, ...
    'CenterFrequency',centerFrequency,'Gain',30,'MasterClockRate',16e6, ...
    'DecimationFactor',16,'SamplesPerFrame',samplesPerFrame, ...
    'OutputDataType','double','ChannelMapping',1);
x = complex(zeros(nFrames*samplesPerFrame,1)); k = 0; overflowCount = 0;
for n = 1:nFrames
    [y,len,overflow] = rx();
    if len > 0, x(k+1:k+len) = y(1:len); k = k + len; end
    overflowCount = overflowCount + overflow;
end
release(rx); x=x(1:k);
N=min(4096,length(x)); w=hann(N); xx=x(1:floor(length(x)/N)*N); xx=reshape(xx,N,[]);
P=mean(abs(fftshift(fft(xx.*w,[],1),1)).^2,2)/(sum(w.^2)*sampleRate);
f=(-N/2:N/2-1)'*sampleRate/N + centerFrequency;
plot(f/1e6,10*log10(P+eps)); grid on; xlabel('MHz'); ylabel('dB/Hz');
title(sprintf('B210 RX, %g MHz, %d overflows',centerFrequency/1e6,overflowCount));
