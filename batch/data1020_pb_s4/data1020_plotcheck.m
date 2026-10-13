function data1020_plotcheck()
set(groot,'defaultFigureVisible','off');
out="F:/matlab-GNSSsdr/BDS/S4repair_basedOnSDR-v2/results/data1020_pb_02_04_05_s4";
s=load(fullfile(out,'preflight','smoke_02_prn27.mat'),'t');
data1020_plot(s.t,fullfile(out,'preflight','figures'),'02 smoke');
fprintf('UTC plotting check completed.\n');
end
