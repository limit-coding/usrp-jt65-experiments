function S=jt65_payload_frame(message,index,opts)
% 每帧七个有效比特：二进制输入重复；ASCII 文字按字符循环。
arguments
    message (1,1) string = "hello"
    index (1,1) double {mustBeInteger,mustBePositive} = 1
    opts.SpeedMode (1,1) string {mustBeMember(opts.SpeedMode,["fast","slow"])} = "fast"
end
T=jt65_timing(opts.SpeedMode);
txt=char(message);
assert(~isempty(txt) && numel(txt)<=32 && all(double(txt)>=32 & double(txt)<=126), ...
    '请输入 7 位二进制数据，或 1–32 个可打印 ASCII 字符，例如 hello。');
if numel(txt)==7 && all(ismember(txt,'01'))
    S=jt65_make_frame(message,SampleRate=T.sampleRate); S.sequenceLength=1; S.characterIndex=1;
else
    k=mod(index-1,numel(txt))+1;
    bits=dec2bin(double(txt(k)),7);
    S=jt65_make_frame(string(bits),SampleRate=T.sampleRate);
    S.msgMode='ascii7'; S.userMsg=txt(k);
    S.sequenceLength=numel(txt); S.characterIndex=k;
end
S.sourceMessage=txt; S.speedMode=char(opts.SpeedMode);
end
