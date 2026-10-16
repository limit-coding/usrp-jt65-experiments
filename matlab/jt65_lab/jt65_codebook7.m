function [gray,payload,messages] = jt65_codebook7()
% 全部 128 种七比特载荷的公开码本。与发送文字、历史接收结果无关。
% 行为候选 0:127，列为发送顺序中的 63 个数据音。
persistent tones words padded
if isempty(tones)
    words=de2bi((0:127).',7,'left-msb');
    padded=[words zeros(128,65)]; tones=zeros(128,63);
    encoder=comm.RSEncoder('BitInput',true,'CodewordLength',63,'MessageLength',12);
    for k=1:128
        code=encoder(padded(k,:).');
        symbols=bi2de(reshape(code,6,[]).','left-msb');
        inter=reshape(symbols,9,7).'; inter=inter(:);
        tones(k,:)=bitxor(inter,floor(inter/2)).';
    end
end
gray=tones; payload=words; messages=padded;
end
