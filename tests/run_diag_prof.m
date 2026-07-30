cd('F:/matlab-GNSSsdr/BDS/B2a');
setupPaths;
outDir = 'F:/matlab-GNSSsdr/BDS/B2a/results/smoke/pvt_260730_resume2';
figDir = fullfile(outDir, 'figures');
if ~exist(figDir, 'dir'), mkdir(figDir); end
set(0, 'DefaultFigureVisible', 'off');
prns = [41 39 38 24];
settings = initSettings('msToProcess', 38000, 'acqSatelliteList', prns, 'numberOfChannels', 12, 'plotTracking', 0);
S = load(fullfile(outDir, 'results.mat'));
smoke = S.smoke;
tr = smoke.trackResults;
nav = smoke.navSolutions;
fprintf('=== Diagnostics ===\n');
for k = 1:4
  absS = tr(k).absoluteSample; absS = absS(isfinite(absS));
  fprintf('PRN%02d absSample first/last=[%.0f %.0f] dN=%.0f\n', tr(k).PRN, absS(1), absS(end), absS(end)-absS(1));
end
if ~isempty(nav) && isfield(nav,'X')
  r = sqrt(nav.X.^2+nav.Y.^2+nav.Z.^2);
  fprintf('ECEF r km min/med/max: %.1f / %.1f / %.1f\n', min(r)/1e3, median(r)/1e3, max(r)/1e3);
  ok = isfinite(nav.X); Xm=mean(nav.X(ok)); Ym=mean(nav.Y(ok)); Zm=mean(nav.Z(ok));
  f=figure('Visible','off','Color','w','Position',[50 50 1100 800]);
  subplot(2,2,1); plot(nav.X(ok)-Xm, nav.Y(ok)-Ym, '.'); axis equal; grid on; title('ECEF dX-dY');
  subplot(2,2,2); plot(nav.X(ok)-Xm, nav.Z(ok)-Zm, '.'); axis equal; grid on; title('ECEF dX-dZ');
  subplot(2,2,3); plot((1:numel(r))*0.5, (r-mean(r(ok)))/1e3, '.-'); grid on; title('d r km');
  subplot(2,2,4); plot(nav.rawP(:,:)'); grid on; title('rawP');
  exportgraphics(f, fullfile(figDir,'nav_ecef_relative.png'), 'Resolution', 150); close(f);
end
if ~isempty(nav) && isfield(nav,'rawP')
  f=figure('Visible','off','Color','w'); imagesc(nav.rawP); colorbar; title('rawP map');
  exportgraphics(f, fullfile(figDir,'nav_rawP_map.png'), 'Resolution', 150); close(f);
end
f=figure('Visible','off','Color','w','Position',[50 50 1000 500]); hold on;
for k=1:4
  cno=tr(k).B2a_CNo; tc=(1:numel(cno))*settings.CNoInterval*1e-3;
  plot(tc,cno,'DisplayName',sprintf('PRN%d',tr(k).PRN));
end
grid on; legend('show'); ylim([20 55]); title('CNo multi-SV');
exportgraphics(f, fullfile(figDir,'trk_cno_multi.png'), 'Resolution', 150); close(f);
dd=dir(fullfile(figDir,'*.png')); fprintf('Figures: %d\n', numel(dd));
for i=1:numel(dd), fprintf('  %s\n', dd(i).name); end
fprintf('=== Profile ===\n');
rankT = profile_track_hotspots('msToProcess',8000,'acqSatelliteList',41,'outDir',fullfile(outDir,'profile'));
save(fullfile(outDir,'diag_and_profile.mat'),'rankT','-v7.3');
fprintf('DONE_DIAG\n');
