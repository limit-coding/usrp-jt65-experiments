% 实验2：JT65 编解码链路 —— 随机 72 bit 信源 <-> 63 个 6bit 信道符号
%
% 正向（发送端）：72 bit -> RS(63,12) -> 378 bit -> 63 个 6bit 符号
%                 -> 交织 -> 格雷映射 -> 63 个 0..63 的符号
% 反向（接收端）：解格雷 -> 解交织 -> RS 解码 -> 72 bit
%
% 交织约定与课程 homework2_jt65_receiver.m 完全一致：按行写入 7x9 矩阵，再按列读出。
% 本脚本是自闭环演示；实验3 用它生成的 63 个符号去调制，实验4 再反着解回来。
clear; clc; rng default;

%% ---------------- 1. 随机信源 72 bit ----------------
msgBits = randi([0 1],72,1);
fprintf('信源：%d bit\n', numel(msgBits));

%% ---------------- 2. 正向：RS 编码 -> 交织 -> 格雷 ----------------
enc       = comm.RSEncoder('BitInput',true,'CodewordLength',63,'MessageLength',12);
codedBits = enc(msgBits);                                % 378 bit = 63 个 6bit 符号
s         = bi2de(reshape(codedBits,6,[]).','left-msb'); % 63 个 0..63
inter     = reshape(s,9,7).'; inter = inter(:);          % 交织：按行写入 7x9，再按列读出
gray      = bitxor(inter,floor(inter/2));                % 格雷映射
fprintf('编码：%d bit -> %d 个 6bit 符号\n', numel(codedBits), numel(gray));

%% ---------------- 3. 反向：解格雷 -> 解交织 -> RS 解码 ----------------
back  = gray;
shift = bitshift(gray,-1);
while any(shift), back = bitxor(back,shift); shift = bitshift(shift,-1); end
deinter = reshape(back,7,9).'; deinter = deinter(:);     % 解交织（与 homework2 一致）
rxBits  = reshape(de2bi(deinter,6,'left-msb').',[],1);
dec       = comm.RSDecoder('BitInput',true,'CodewordLength',63,'MessageLength',12);
recovered = dec(rxBits);

%% ---------------- 4. 往返结果 ----------------
nErr = nnz(msgBits ~= recovered);
fprintf('译码：%d bit，与信源比对错误 %d bit\n', numel(recovered), nErr);
fprintf('往返一致：%d\n', isequal(msgBits(:), recovered(:)));

%% ---------------- 5. 输出生成的 72 bit 与 63x6 bit ----------------
sym6 = de2bi(gray, 6, 'left-msb');      % 63x6，每行是一个符号的 6 bit（高位在前）

fprintf('\n======== 信源 72 bit（12 个 6bit 信息符号）========\n');
fprintf(' 序号    6bit     十进制\n');
for k = 1:12
    b = msgBits((k-1)*6 + (1:6)).';                      % 1x6 行向量（bi2de 按行取值）
    fprintf('%5d    %s      %3d\n', k, sprintf('%d',b), bi2de(b,'left-msb'));
end
fprintf('连续 72 bit：');
fprintf('%d', msgBits); fprintf('\n');

fprintf('\n======== 63 个信道符号（63x6 bit）========\n');
fprintf(' 序号    6bit     十进制\n');
for k = 1:63
    fprintf('%5d    %s      %3d\n', k, sprintf('%d',sym6(k,:)), gray(k));
end
fprintf('对应的 63 个整数符号：\n');
fprintf('%3d', gray); fprintf('\n');

% 存盘，便于写报告或后续实验直接取用
outDir = fullfile(fileparts(mfilename('fullpath')),'..','..','data');
if ~exist(outDir,'dir'), mkdir(outDir); end
outFile = fullfile(outDir,'jt65_codec_out.mat');
save(outFile, 'msgBits', 'codedBits', 's', 'inter', 'gray', 'sym6', 'recovered');
fprintf('\n已保存 %s\n', outFile);
fprintf('  变量：msgBits(72x1) codedBits(378x1) s(63x1) inter(63x1) gray(63x1) sym6(63x6) recovered(72x1)\n');

%% ---------------- 6. 作图 ----------------
figure('Name','实验2 编解码结果','Position',[120 120 900 620]);
subplot(2,1,1);
stem(0:62, gray, 'filled'); grid on;
xlabel('符号序号'); ylabel('格雷符号 (0..63)');
title(sprintf('实验2：随机 72 bit 编出的 63 个信道符号（往返错误 %d bit）', nErr));
subplot(2,1,2);
stem(0:71, msgBits, 'filled'); hold on; stem(0:71, recovered, 'x'); grid on;
legend('信源','译码恢复'); xlabel('比特序号'); ylabel('比特值');
title('72 bit 信源与译码结果对比');
saveas(gcf, fullfile(outDir,'jt65_codec.png'));
fprintf('图已保存 %s\n', fullfile(outDir,'jt65_codec.png'));
