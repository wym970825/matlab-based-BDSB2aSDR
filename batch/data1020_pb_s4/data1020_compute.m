function [t,d,track] = data1020_compute(c,prn,maxWindows)
cfg=c.cfg; cfg.prns=prn; cfg.maxWindows=maxWindows;
track=s4repair.io.loadTrackChunks(cfg.resultDir,prn,cfg);
[t,d]=s4repair.s4.processAlignedTrack(track,c.anchors,c.settings,cfg);
t.hardwareRuleResult=t.frontEndResponseVerified;
t.hardwareValidityForced=repmat(cfg.forceHardwareValid,height(t),1);
t.frontEndResponseVerified(:)=true;
t.proposedValid=t.proposedModelValid;
t.comparisonValid=t.proposedValid & t.conventionalValid;
t.isUsable=t.comparisonValid;
t.qualityCode=strip(replace(t.qualityCode,"UNCALIBRATED_FRONTEND_RESPONSE",""),'both','|');
t.qualityCode(strlength(t.qualityCode)==0)="OK";
forcedStatus=t.repairStatus=="UNCALIBRATED_FRONTEND_RESPONSE";
t.repairStatus(forcedStatus & t.proposedModelValid)="OK";
t.repairStatus(forcedStatus & ~t.proposedModelValid)=t.qualityCode(forcedStatus & ~t.proposedModelValid);
d.calibration.hardwareRuleResult=d.calibration.frontEndResponseVerified;
d.calibration.frontEndResponseVerified=true;
d.calibration.frontEndVerification="Forced true by user configuration for DATA1020 PB 02/04/05";
t.experimentNumber=repmat(c.entry.experimentNumber,height(t),1);
t.sourceId=repmat(string(c.entry.sourceId),height(t),1);
t.windowStartUtc.Format="yyyy-MM-dd'T'HH:mm:ss.SSSXXX";
t.windowEndUtc.Format="yyyy-MM-dd'T'HH:mm:ss.SSSXXX";
fprintf('External cfg: hardwareValid=true; experiment=%02d PRN=%02d proposed=%d/%d common=%d/%d\n', ...
    c.entry.experimentNumber,prn,nnz(t.proposedValid),height(t),nnz(t.comparisonValid),height(t));
end
