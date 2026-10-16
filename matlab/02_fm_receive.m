% Narrowband implementation of a WFM receive test. Saves baseband audio to WAV.
clear; clc;
serialNum='347380A'; fc=100.6e6; rfRate=1e6; seconds=10; frame=20000;
rx=comm.SDRuReceiver('Platform','B210','SerialNum',serialNum, ...
 'CenterFrequency',fc,'Gain',30,'MasterClockRate',16e6,'DecimationFactor',16, ...
 'SamplesPerFrame',frame,'OutputDataType','double','ChannelMapping',1);
z=complex(zeros(seconds*rfRate,1)); k=0;
for n=1:ceil(seconds*rfRate/frame), [y,len]=rx(); if len>0, z(k+1:k+len)=y(1:len); k=k+len; end, end
release(rx); z=z(1:k);
audio=angle(z(2:end).*conj(z(1:end-1))); audio=audio-mean(audio);
N=2^nextpow2(length(audio)); A=fft(audio,N); f=(0:N-1)'*rfRate/N; mask=(f<100e3)|(f>rfRate-100e3); A(~mask)=0; audio=real(ifft(A));
audio=resample(audio,48000,rfRate); audio=0.5*audio/max(1,max(abs(audio))); audiowrite('data/fm_matlab.wav',audio,48000);
fprintf('saved data/fm_matlab.wav\n'); sound(audio,48000);
