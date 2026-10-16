function S = jt65_make_frame(userMsg, opts)
% 保持原始 516096 点；按指定采样率播放。默认加速实验：2.52 秒。
arguments
    userMsg (1,1) string = "1011010"
    opts.SampleRate (1,1) double {mustBePositive} = 204800
end
txt = char(userMsg);
assert(~isempty(txt) && numel(txt)<=9 && all(double(txt)<128), ...
    '请输入 1 到 9 个 ASCII 字符，例如 hello 或 test123。');
txt = [txt repmat(' ',1,9-numel(txt))];
S = struct('fs',11025,'nSamp',4096,'nSlot',126,'fSync',1270.5, ...
    'df',2.6917,'mSub',1,'userMsg',char(userMsg),'msgMode','text');
S.msgBits = reshape(de2bi(double(txt),8,'left-msb').',[],1);
% 七位二进制输入作为有效载荷，其余 65 位只用于补齐 RS 输入。
if strlength(userMsg)==7 && all(ismember(char(userMsg),'01'))
    S.msgMode='bits7';
    S.msgBits=[double(char(userMsg).'-'0');zeros(65,1)];
    S.payloadIndices=(1:7).';
else
    S.payloadIndices=(1:72).'; % 兼容旧的文字实验。
end
S.payloadBits=S.msgBits(S.payloadIndices);
S.payloadBitCount=numel(S.payloadIndices);
encoder = comm.RSEncoder('BitInput',true,'CodewordLength',63,'MessageLength',12);
bits = encoder(S.msgBits);
s = bi2de(reshape(bits,6,[]).','left-msb');
inter = reshape(s,9,7).'; inter = inter(:);
S.gray = bitxor(inter,floor(inter/2));
S.sync = [1,0,0,1,1,0,0,0,1,1,1,1,1,1,0,1,0,1,0,0,0,1,0,1,1,0,0,1,0,0, ...
    0,1,1,1,0,0,1,1,1,1,0,1,1,0,1,1,1,1,0,0,0,1,1,0,1,0,1,0,1,1, ...
    0,0,1,1,0,1,0,1,0,1,0,0,1,0,0,0,0,0,0,1,1,0,0,0,0,0,0,0,1,1, ...
    0,1,0,0,1,0,1,1,0,1,0,1,0,1,0,0,1,1,0,0,1,0,0,1,0,0,0,0,1,1, ...
    1,1,1,1,1,1].';
S.toneIdx = zeros(S.nSlot,1);
S.toneIdx(S.sync==0) = S.gray+2;
S.freq = S.fSync+S.df*S.toneIdx;
S.wave = complex(zeros(S.nSlot*S.nSamp,1));
t = (0:S.nSamp-1).'/S.fs; phase=0;
for k=1:S.nSlot
    S.wave((k-1)*S.nSamp+(1:S.nSamp)) = exp(1i*(2*pi*S.freq(k)*t+phase));
    phase = mod(phase+2*pi*S.freq(k)*S.nSamp/S.fs,2*pi);
end
% 只改播放时钟和频率标注；不插值、不增加波形采样点。
S.originalFs=S.fs; S.speedScale=opts.SampleRate/S.originalFs;
S.fs=opts.SampleRate;
S.fSync=S.fSync*S.speedScale; S.df=S.df*S.speedScale; S.freq=S.freq*S.speedScale;
end

