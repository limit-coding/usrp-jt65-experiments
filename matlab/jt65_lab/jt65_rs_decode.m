function [decoded, correctedCount, D] = jt65_rs_decode(bits, mlEnergy, mode)
%JT65_RS_DECODE 硬判决优先；失败后按接收能量可靠度尝试 RS 纠错/擦除。
% 不接收发送消息或参考码字。擦除位置跟随解交织恢复到 RS 码字顺序。
% 限制最多 40 个擦除，保留 11 个冗余符号；不会擦除 51 位后强行插值。
arguments
    bits (:,1) double
    mlEnergy (64,63) double
    mode (1,1) string {mustBeMember(mode,["hard","erasure"])} = "erasure"
end
hard=comm.RSDecoder('BitInput',true,'CodewordLength',63,'MessageLength',12, ...
    'NumCorrectedErrorsOutputPort',true);
[decoded,correctedCount]=hard(bits);
D=struct('mode',char(mode),'hardAccepted',correctedCount>=0, ...
    'usedErasures',0,'attempts',1,'candidateCount',double(correctedCount>=0));
if correctedCount>=0 || mode=="hard", return; end
sorted=sort(mlEnergy,1,'descend');
noise=max(mean(sorted(3:end,:),1),realmin);
reliability=[(sorted(1,:)-sorted(2,:))./noise; ...
    (sorted(1,:)-sorted(2,:))./max(sorted(1,:),realmin); sorted(1,:)./noise];
soft=comm.RSDecoder('BitInput',true,'CodewordLength',63,'MessageLength',12, ...
    'NumCorrectedErrorsOutputPort',true,'ErasuresInputPort',true);
encoder=comm.RSEncoder('BitInput',true,'CodewordLength',63,'MessageLength',12);
best=-Inf;
stream=RandStream('mt19937ar','Seed',65063);
for r=1:103
    rankType=mod(r-1,3)+1;
    rel=reshape(reliability(rankType,:),7,9).'; rel=rel(:);
    if r>3
        rel=(rel+0.05).*(-log(max(rand(stream,63,1),realmin)));
    end
    [~,order]=sort(rel,'ascend');
    for nErase=2:2:40
        erased=false(63,1); erased(order(1:nErase))=true;
        [candidate,count]=soft(bits,erased); D.attempts=D.attempts+1;
        if count<0, continue; end
        code=encoder(candidate);
        symbols=bi2de(reshape(code,6,[]).','left-msb');
        inter=reshape(symbols,9,7).'; inter=inter(:);
        gray=bitxor(inter,floor(inter/2));
        metric=sum(mlEnergy(sub2ind([64 63],gray.'+1,1:63))./noise);
        D.candidateCount=D.candidateCount+1;
        if metric>best
            best=metric; decoded=candidate; correctedCount=count;
            D.usedErasures=nErase;
        end
    end
end
end
