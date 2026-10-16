function [decoded,accepted,D] = jt65_decode7(energy,backgroundPower)
%JT65_DECODE7 根据整帧软能量比较全部 128 个七比特码字；允许拒绝输出。
% 输入仅为接收端数据音能量及公开同步时隙的同频背景，不能访问发送参考。
% 各时隙噪声尺度未知，用目标音能量占全部音能量的比例 u 消去尺度。
% 模型：正交音的复高斯噪声，目标音另有独立复高斯信号，功率比 rho。
% 相对纯噪声的似然比为 (1+rho)^-1*(1-rho/(1+rho)*u)^-64。
% 对固定 rho 网格等权混合，避免对每个候选无限拟合信号强度。
% 这是保守的非相干模型分数；真实干扰及同步搜索下不保证误报概率。
arguments
    energy (64,63) double {mustBeNonnegative,mustBeFinite}
    backgroundPower (64,1) double {mustBeNonnegative,mustBeFinite}
end
[gray,~,messages]=jt65_codebook7();
% 同步时隙不发送数据音；用它们测量各频点的背景，压制持续窄带干扰。
% 下限防止有限样本偶然低估背景时把单一音调无限放大。
background=max(backgroundPower,max(median(backgroundPower)/2,realmin));
energy=energy./background;
% 所有候选相同的已知补零符号不提供载荷区分证据，不能替候选加分。
columns=find(any(gray~=gray(1,:),1));
totals=sum(energy,1); u=energy./max(totals,realmin);
selected=u(sub2ind([64 63],gray(:,columns)+1,repmat(columns,128,1)));
rho=[0.25 0.5 1 2 4 8 16 32 64 128 256 512 1024 4096];
gridScores=zeros(128,numel(rho));
for k=1:numel(rho)
    lambda=rho(k)/(1+rho(k));
    gridScores(:,k)=sum(-log1p(rho(k))-64*log1p(-lambda*selected),2);
end
peak=max(gridScores,[],2);
scores=peak+log(mean(exp(gridScores-peak),2));
[ranked,order]=sort(scores,'descend');
logOdds=ranked(1)-(ranked(2)+log(sum(exp(ranked(2:end)-ranked(2)))));
% 固定假设下每个混合似然比在纯噪声中的期望为 1。
% 固定模型的名义 alpha=1e-6；另要求胜者相对其余之和 >=999。
% 使用估计背景和同步搜索后，该 alpha 仅为门限参数，非实际误报率保证。
logEvidenceThreshold=log(128/1e-6); logOddsThreshold=log(999);
accepted=all(totals>0) && ranked(1)>=logEvidenceThreshold && logOdds>=logOddsThreshold;
decoded=messages(order(1),:).'; % 未接受时仅作诊断候选，不计入有效 BER。
reason='accepted';
if ranked(1)<logEvidenceThreshold || any(totals<=0), reason='insufficient_evidence';
elseif logOdds<logOddsThreshold, reason='ambiguous_candidates'; end
D=struct('mode','joint7','candidateCount',128,'attempts',128,'usedErasures',0, ...
    'hardAccepted',false,'accepted',accepted,'reason',reason, ...
    'bestValue',order(1)-1,'runnerUpValue',order(2)-1, ...
    'logEvidence',ranked(1),'logEvidenceThreshold',logEvidenceThreshold, ...
    'logOdds',logOdds,'logOddsThreshold',logOddsThreshold, ...
    'modelPosterior',1/(1+exp(-logOdds)),'candidateLogEvidence',scores, ...
    'informativeColumns',columns,'rhoGrid',rho,'nominalNoiseAlpha',1e-6, ...
    'backgroundPower',backgroundPower);
end
