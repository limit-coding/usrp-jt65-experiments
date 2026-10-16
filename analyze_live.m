C=load('data/jt65_live_20261013_152453_163/rx_capture.mat');
S=load('data/jt65_live_20261013_152453_163/tx_reference.mat');
rx=C.rx; fs=C.fsRx;
fprintf('采集 %d 点，%.2f s @ %d Hz\n',numel(rx),numel(rx)/fs,fs);
fprintf('全段平均功率 %.1f dBFS\n',20*log10(rms(rx)+eps));
x=decimate(real(rx),2,'fir')+1i*decimate(imag(rx),2,'fir');
L=S.nSamp/2; fsd=fs/2;
tau=round(3.1371*fsd);
frame=x(tau+(1:S.nSlot*L)); nf=numel(frame);
spec=abs(fftshift(fft(frame.*hann(nf)))); f=(-floor(nf/2):ceil(nf/2)-1)'*fsd/nf;
band=f>1150&f<1550; s=spec(band); fb=f(band);
[pk,ip]=max(s);
fprintf('带内峰值 %.2f Hz，超出噪声底 %.1f dB\n',fb(ip),20*log10(pk/median(s)));
fprintf('同步音位置幅度 vs 噪声底：%.1f dB\n',20*log10(s(abs(fb-S.fSync)<2)/median(s)));
% 用脚本同款 syncScore 扫全段
mix=x.*exp(-2i*pi*S.fSync*(0:numel(x)-1).'/fsd);
cs=[0;cumsum(mix)]; a=abs(cs(L+1:end)-cs(1:end-L));
tauMax=numel(x)-S.nSlot*L; syncAmp=zeros(tauMax+1,1); dataAmp=syncAmp;
starts=(1:tauMax+1).';
for k=1:S.nSlot
  v=a(starts+(k-1)*L);
  if S.sync(k), syncAmp=syncAmp+v; else, dataAmp=dataAmp+v; end
end
sc=(syncAmp-dataAmp)./(syncAmp+dataAmp+eps);
[best,bp]=max(sc);
fprintf('最高同步得分 %.3f @ %.4f s\n',best,(bp-1)/fsd);
% 不管门限，直接解调 + RS
x=x.*exp(-2i*pi*(fb(ip)-S.fSync)*(0:numel(x)-1).'/fsd);
tones=S.fSync+S.df*((0:63)+2); refs=exp(2i*pi*(0:L-1).'/fsd*tones);
dataPos=find(S.sync==0); sym=zeros(63,1);
for j=1:63
  w=x(tau+(dataPos(j)-1)*L+(1:L));
  [~,idx]=max(abs(refs'*w).^2); sym(j)=idx-1;
end
fprintf('解调符号错误 %d/63\n',nnz(sym~=S.gray));
back=sym; sh=bitshift(back,-1);
while any(sh), back=bitxor(back,sh); sh=bitshift(sh,-1); end
deinter=reshape(back,7,9).'; deinter=deinter(:);
bits=reshape(de2bi(deinter,6,'left-msb').',[],1);
dec=comm.RSDecoder('BitInput',true,'CodewordLength',63,'MessageLength',12);
msg=dec(bits); txt=char(bi2de(reshape(msg,8,[]).','left-msb')).';
fprintf('RS 后比特错误 %d/72，解出："%s"\n',nnz(msg~=S.msgBits),txt);
