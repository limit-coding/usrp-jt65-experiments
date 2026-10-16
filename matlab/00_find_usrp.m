% Check the B210 connection and print the detected serial number.
clear; clc;
radios = findsdru;
disp(radios);
if isempty(radios), error('没有找到 USRP。请检查 USB3、驱动和 Support Package。'); end
ok = strcmp({radios.Status}, 'Success');
if ~any(ok), error('找到设备但 MATLAB 状态不是 Success。'); end
fprintf('可用设备：%s，序列号：%s\n', radios(find(ok,1)).Platform, radios(find(ok,1)).SerialNum);
