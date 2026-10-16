function A=jt65_accumulate(A,P)
% 累计时以比特总数为分母，不平均每帧 BER。失败帧单列，不藏入零误码。
if isempty(A)
    A=struct('frames',0,'passedFrames',0,'failedFrames',0,'transportFailedFrames',0, ...
        'sentText','','receivedText','','payloadBitsSent',0,'decodedFrames',0,'codedBits',0,'codedErrors',0,'decodedBits',0,'decodedErrors',0, ...
        'unknownMessageBits',0,'codedBer',NaN,'decodedBer',NaN,'frameErrorRate',NaN, ...
        'messageBerBounds',[0 1],'history',zeros(0,5));
end
A.frames=A.frames+1; R=P.result;
if isfield(P.S,'payloadBitCount'), nBits=P.S.payloadBitCount; else, nBits=numel(P.S.msgBits); end
A.payloadBitsSent=A.payloadBitsSent+nBits;
if ~isempty(R) && R.transportClean
    A.codedBits=A.codedBits+numel(R.validation.codedBits);
    A.codedErrors=A.codedErrors+R.validation.codedBitErrors;
    if R.decoderAccepted
        A.decodedFrames=A.decodedFrames+1;
        A.decodedBits=A.decodedBits+nBits;
        A.decodedErrors=A.decodedErrors+R.bitErrors;
    else
        A.unknownMessageBits=A.unknownMessageBits+nBits;
    end
else
    A.unknownMessageBits=A.unknownMessageBits+nBits;
    if ~isempty(R) && ~R.transportClean, A.transportFailedFrames=A.transportFailedFrames+1; end
end
passed=~isempty(R) && R.passed;
if isfield(P.S,'msgMode') && strcmp(P.S.msgMode,'ascii7')
    A.sentText=[A.sentText P.S.userMsg];
    if ~isempty(R) && R.transportClean && R.decoderAccepted
        A.receivedText=[A.receivedText R.message];
    else
        A.receivedText=[A.receivedText '?']; % 占位保留帧位置，不用发送参考填补。
    end
end
A.passedFrames=A.passedFrames+passed; A.failedFrames=A.frames-A.passedFrames;
A.frameErrorRate=A.failedFrames/A.frames;
if A.codedBits>0, A.codedBer=A.codedErrors/A.codedBits; end
if A.decodedBits>0, A.decodedBer=A.decodedErrors/A.decodedBits; end
allBits=A.decodedBits+A.unknownMessageBits;
A.messageBerBounds=[A.decodedErrors,A.decodedErrors+A.unknownMessageBits]/allBits;
A.history(end+1,:)=[A.frames,A.codedBer,A.decodedBer,A.frameErrorRate,double(passed)];
end
