function report=test_jt65_joint7(opts)
% 无射频测试：全码本、拒判控制、随机消息的能量域 A/B。
arguments
    opts.Trials (1,1) double {mustBeInteger,mustBePositive} = 200
    opts.NoiseTrials (1,1) double {mustBeInteger,mustBePositive} = 10000
    opts.Seed (1,1) double {mustBeInteger,mustBeNonnegative} = 651017
end
rng(opts.Seed,'twister'); [gray,payload,messages]=jt65_codebook7();
for v=0:127
    S=jt65_make_frame(string(dec2bin(v,7)));
    assert(isequal(S.gray.',gray(v+1,:)) && isequal(S.msgBits.',messages(v+1,:)));
    E=ones(64,63); E(sub2ind([64 63],gray(v+1,:)+1,1:63))=100;
    [decoded,ok]=jt65_decode7(E,ones(64,1));
    assert(ok && isequal(decoded(1:7).',payload(v+1,:)));
end
[~,ok]=jt65_decode7(zeros(64,63),ones(64,1)); assert(~ok);
% 两个同强码字，不能强行选其中一个。
E=ones(64,63);
for k=[17 93], E(sub2ind([64 63],gray(k,:)+1,1:63))=100; end
[~,ok,D]=jt65_decode7(E,ones(64,1)); assert(~ok && strcmp(D.reason,'ambiguous_candidates'));
noiseAccepted=0; toneAccepted=0;
for k=1:opts.NoiseTrials
    E=abs((randn(64,63)+1i*randn(64,63))/sqrt(2)).^2;
    B=abs((randn(64,63)+1i*randn(64,63))/sqrt(2)).^2;
    [~,ok]=jt65_decode7(E,mean(B,2)); noiseAccepted=noiseAccepted+ok;
    tone=mod(k-1,64)+1; E(tone,:)=E(tone,:)+100; B(tone,:)=B(tone,:)+100;
    [~,ok]=jt65_decode7(E,mean(B,2)); toneAccepted=toneAccepted+ok;
end
fprintf('控制测试 %d 次：纯噪声误接收 %d，持续单音误接收 %d。\n',opts.NoiseTrials,noiseAccepted,toneAccepted);
levels=[-18 -16 -14 -12 -10 -8]; % 快速模式、2500 Hz 参考；理想已同步能量域。
rows=zeros(numel(levels),8);
for j=1:numel(levels)
    rho=2500*0.02*10^(levels(j)/10); counts=zeros(1,6);
    for k=1:opts.Trials
        v=randi(128); z=(randn(64,63)+1i*randn(64,63))/sqrt(2);
        ix=sub2ind([64 63],gray(v,:)+1,1:63);
        z(ix)=z(ix)+sqrt(rho)*exp(2i*pi*rand(1,63)); E=abs(z).^2;
        B=mean(abs((randn(64,63)+1i*randn(64,63))/sqrt(2)).^2,2);
        [d,a]=jt65_decode7(E,B); correct=isequal(d(1:7).',payload(v,:));
        counts(1:3)=counts(1:3)+[a&&correct a&&~correct ~a];
        [~,sym]=max(E,[],1); back=sym.'-1; shift=bitshift(back,-1);
        while any(shift), back=bitxor(back,shift); shift=bitshift(shift,-1); end
        deinter=reshape(back,7,9).'; deinter=deinter(:);
        bits=reshape(de2bi(deinter,6,'left-msb').',[],1);
        [d,n]=jt65_rs_decode(bits,E,"hard"); a=n>=0; correct=isequal(d(1:7).',payload(v,:));
        counts(4:6)=counts(4:6)+[a&&correct a&&~correct ~a];
    end
    rows(j,:)=[levels(j) opts.Trials counts];
end
report=struct('allValuesPassed',128,'noiseTrials',opts.NoiseTrials, ...
    'seed',opts.Seed, ...
    'noiseAccepted',noiseAccepted,'stationaryToneAccepted',toneAccepted, ...
    'energyDomain',array2table(rows,'VariableNames',{'Snr2500Db','Trials','JointCorrect','JointWrong','JointRejected','HardCorrect','HardWrong','HardRejected'}));
disp(report); disp(report.energyDomain);
end
