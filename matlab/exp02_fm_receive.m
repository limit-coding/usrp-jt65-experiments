% Narrowband implementation of a WFM receive test. Saves baseband audio to WAV.
clear; clc;
serialNum='347380A'; fc=100.6e6; rfRate=1e6; seconds=10; frame=20000;
rx=comm.SDRuReceiver('Platform','B210','SerialNum',serialNum, ...
 'CenterFrequency',fc,'Gain',30,'MasterClockRate',16e6,'DecimationFactor',16, ...
 'SamplesPerFrame',frame,'OutputDataType','double','ChannelMapping',1);
z=complex(zeros(seconds*rfRate,1)); k=0;
for n=1:ceil(seconds*rfRate/frame), [y,len]=rx(); if len>0, z(k+1:k+len)=y(1:len); k=k+len; end, end
release(rx); z=z(1:k);
% Channel filter: keep only +/-100 kHz. Without this the discriminator also
% demodulates the adjacent FM stations that fall inside the 1 MHz capture band.
h=fir1(200,100e3/(rfRate/2)); z=filter(h,1,z);
audio=angle(z(2:end).*conj(z(1:end-1))); audio=audio-mean(audio);
% Zero-padded FFT filtering. ifft(A) returns N points, not the original length,
% so keep n0 and truncate back -- otherwise the audio is stretched by
% N/n0 and plays at the wrong speed.
n0=length(audio);
N=2^nextpow2(n0); A=fft(audio,N); f=(0:N-1)'*rfRate/N; mask=(f<100e3)|(f>rfRate-100e3); A(~mask)=0; audio=real(ifft(A)); audio=audio(1:n0);
% run() cd's to this script's folder, so 'data/' would resolve to matlab/data/.
% Anchor the output at the project root instead, and create it if missing.
outDir=fullfile(fileparts(mfilename('fullpath')),'..','data');
if ~exist(outDir,'dir'), mkdir(outDir); end
audio=resample(audio,48000,rfRate); audio=0.5*audio/max(1,max(abs(audio)));
outFile=fullfile(outDir,'fm_matlab.wav'); audiowrite(outFile,audio,48000);
fprintf('saved %s\n',outFile); sound(audio,48000);
