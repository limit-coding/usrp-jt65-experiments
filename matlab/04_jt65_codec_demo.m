% JT65 teaching exercise from 实验2: 72 bits -> RS(63,12) -> interleave -> Gray.
clear; clc; rng default; msgBits=randi([0 1],72,1);
enc=comm.RSEncoder('BitInput',true,'CodewordLength',63,'MessageLength',12);
dec=comm.RSDecoder('BitInput',true,'CodewordLength',63,'MessageLength',12);
codedBits=enc(msgBits); s=bi2de(reshape(codedBits,6,[]).','left-msb');
inter=reshape(s,7,9).'; inter=inter(:); gray=bitxor(inter,floor(inter/2));
back=gray; shift=bitshift(gray,-1);
while any(shift), back=bitxor(back,shift); shift=bitshift(shift,-1); end
deinter=reshape(back,9,7).'; deinter=deinter(:);
rxBits=reshape(de2bi(deinter,6,'left-msb').',[],1); recovered=dec(rxBits);
fprintf('message bits: %d, channel symbols: %d, bit errors after inverse chain: %d\n',length(msgBits),length(gray),nnz(msgBits~=recovered));
stem(gray,'filled'); xlabel('symbol'); ylabel('Gray symbol 0..63'); title('JT65 教学编码序列');
