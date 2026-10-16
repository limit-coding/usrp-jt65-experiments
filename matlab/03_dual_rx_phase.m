% Capture two coherent B210 RX channels and estimate relative phase.
clear; clc; serialNum='347380A'; fc=433e6; frame=20000; frames=50;
rx=comm.SDRuReceiver('Platform','B210','SerialNum',serialNum,'CenterFrequency',fc, ...
 'Gain',30,'MasterClockRate',16e6,'DecimationFactor',16,'SamplesPerFrame',frame, ...
 'OutputDataType','double','ChannelMapping',[1 2]);
x=[]; y=[];
for n=1:frames, [a,len]=rx(); if len>0, x=[x;a(1:len,1)]; y=[y;a(1:len,2)]; end, end
release(rx); c=(y'*x)/(sqrt(y'*y)*sqrt(x'*x)+eps);
fprintf('RMS RX1 %.4g, RX2 %.4g, relative phase %.2f deg, coherence %.4f\n',rms(x),rms(y),angle(c)*180/pi,abs(c));
