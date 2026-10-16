function T=jt65_timing(speedMode)
% 波形分析采样率与硬件采样率分开：慢速模式保持原始符号时长。
arguments
    speedMode (1,1) string {mustBeMember(speedMode,["fast","slow"])} = "fast"
end
fs=204800; label='快速';
if speedMode=="slow", fs=11025; label='慢速'; end
radioRate=204800; chunk=4096; guardSeconds=0.2;
waveSamples=126*4096;
radioWaveSamples=ceil(waveSamples*radioRate/fs);
nLead=ceil(guardSeconds*radioRate/chunk)*chunk;
nTotal=ceil((nLead+radioWaveSamples+guardSeconds*radioRate)/chunk)*chunk;
frameSeconds=nTotal/radioRate;
T=struct('speedMode',char(speedMode),'label',label,'sampleRate',fs, ...
    'radioRate',radioRate,'chunk',chunk,'guardSeconds',guardSeconds, ...
    'payloadSeconds',waveSamples/fs,'radioWaveSamples',radioWaveSamples, ...
    'nLead',nLead,'nTotal',nTotal,'frameSeconds',frameSeconds, ...
    'minuteFrames',max(1,floor(60/frameSeconds)));
end
