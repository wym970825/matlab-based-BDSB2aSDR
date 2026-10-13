function data1020_plot(t,out,label)
mkdir(out); ps=unique(t.PRN);
for page=1:ceil(numel(ps)/4)
    f=newfigure(17.4,12.5); lay=tiledlayout(f,2,2,'TileSpacing','compact','Padding','compact');
    use=ps((page-1)*4+1:min(page*4,numel(ps)));
    for j=1:numel(use)
        ax=nexttile(lay); a=t(t.PRN==use(j),:); curves(ax,a);
        title(ax,sprintf('PRN %02d',use(j)));
    end
    title(lay,label+" / UTC 2022-10-20",'FontSize',8,'FontWeight','normal');
    exportfig(f,out,sprintf('s4_page_%02d',page));
end
for p=ps'
    a=t(t.PRN==p,:); f=newfigure(17.4,12.5);
    lay=tiledlayout(f,2,1,'TileSpacing','compact','Padding','compact');
    ax=nexttile(lay); curves(ax,a); title(ax,sprintf('%s / PRN %02d',label,p));
    ax=nexttile(lay); hold(ax,'on');
    x=a.windowStartUtc+seconds(30); v=a.comparisonValid;
    delta=[a.S4Observed-a.S4Proposed,a.S4Conventional-a.S4Proposed]; delta(~v,:)=NaN;
    plot(ax,x,delta(:,1),'--^','Color',[.52 .52 .52]);
    plot(ax,x,delta(:,2),'--o','Color',[0 .447 .698]);
    yline(ax,0,':'); ylabel(ax,'S_4 difference');
    legend(ax,{'obs - proposed','conventional - proposed'},'Location','northoutside','Orientation','horizontal','Box','off');
    utcaxis(ax,a); exportfig(f,out,sprintf('prn%02d_s4',p));
    f=newfigure(17.4,12.5); lay=tiledlayout(f,4,1,'TileSpacing','compact','Padding','compact');
    vars=["etaMean","loggedPilotCN0DbHz","fitNormalizedRmse","RI"];
    labels=["PB duty","Pilot C/N_0 (dB-Hz)","Fit RMSE","I/N"];
    for k=1:4
        ax=nexttile(lay); plot(ax,x,a.(vars(k)),'-o','Color',[.45 .25 .5]);
        ylabel(ax,labels(k)); utcaxis(ax,a);
    end
    title(lay,sprintf('%s / PRN %02d diagnostics',label,p),'FontSize',8);
    exportfig(f,out,sprintf('prn%02d_diagnostics',p));
end
means=nan(numel(ps),3); counts=zeros(numel(ps),4);
for j=1:numel(ps)
    a=t(t.PRN==ps(j),:); b=a(a.comparisonValid,:);
    means(j,:)=[mean(b.S4Observed),mean(b.S4Conventional),mean(b.S4Proposed)];
    counts(j,:)=[height(a),nnz(a.conventionalValid),nnz(a.proposedValid),nnz(a.comparisonValid)];
end
f=newfigure(17.4,12.5); lay=tiledlayout(f,2,1,'TileSpacing','compact','Padding','compact');
ax=nexttile(lay); h=bar(ax,ps,means,'grouped');
colors=[.52 .52 .52;0 .447 .698;.835 .369 0];
for k=1:3,h(k).FaceColor=colors(k,:);end
ylabel(ax,'Mean S_4 (common windows)'); xlabel(ax,'PRN');
legend(ax,{'Observed','Conventional','Proposed'},'Location','northoutside','Orientation','horizontal','Box','off'); style(ax);
ax=nexttile(lay); bar(ax,ps,counts,'grouped'); ylabel(ax,'UTC-minute windows'); xlabel(ax,'PRN');
legend(ax,{'All','Conventional','Proposed','Common'},'Location','northoutside','Orientation','horizontal','Box','off'); style(ax);
title(lay,label+" / summary",'FontSize',8);exportfig(f,out,'s4_summary');
end

function curves(ax,a)
hold(ax,'on'); x=a.windowStartUtc+seconds(30);
y=[a.S4Observed,a.S4Conventional,a.S4Proposed];y(~a.comparisonValid,:)=NaN;
plot(ax,x,y(:,1),'--^','Color',[.52 .52 .52],'MarkerSize',4);
plot(ax,x,y(:,2),'--o','Color',[0 .447 .698],'MarkerSize',4);
plot(ax,x,y(:,3),'-s','Color',[.835 .369 0],'MarkerSize',4);
ylabel(ax,'S_4'); legend(ax,{'S_{4,obs}','S_{4,conventional}','S_{4,proposed}'}, ...
    'Location','northoutside','Orientation','horizontal','Box','off','FontSize',8);
utcaxis(ax,a); text(ax,.02,.94,sprintf('Common: %d / %d',nnz(a.comparisonValid),height(a)), ...
    'Units','normalized','VerticalAlignment','top','FontSize',8);
end

function utcaxis(ax,a)
style(ax);xlim(ax,[min(a.windowStartUtc),max(a.windowEndUtc)]);
xticks(ax,min(a.windowStartUtc):minutes(1):max(a.windowEndUtc));
xtickformat(ax,'HH:mm:ss');xlabel(ax,'UTC 2022-10-20');
end
function style(ax)
set(ax,'FontName','Arial','FontSize',8,'TickDir','out','Box','off','LineWidth',.65);
end
function f=newfigure(w,h)
f=figure('Visible','off','Color','w','Units','centimeters','Position',[2 2 w h], ...
    'PaperUnits','centimeters','PaperPosition',[0 0 w h],'PaperSize',[w h]);
end
function exportfig(f,out,stem)
set(findall(f,'-property','FontName'),'FontName','Arial'); drawnow;
file=fullfile(out,stem);
print(f,file+'.png','-dpng','-r600');
exportgraphics(f,file+'.pdf','ContentType','vector','BackgroundColor','white');
print(f,file+'.eps','-depsc','-painters');print(f,file+'.svg','-dsvg');savefig(f,file+'.fig');close(f);
end
