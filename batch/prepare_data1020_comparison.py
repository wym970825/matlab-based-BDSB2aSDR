"""Plan the six-case relocation and preserve the evidence for TF station choices.

Directory moves are performed separately with checked PowerShell LiteralPath
operations. This script never deletes raw recordings or result directories.
"""
from pathlib import Path
import argparse
import json


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root',type=Path)
    args=parser.parse_args(); root=args.root.resolve()
    read=lambda p:json.loads(p.read_text(encoding='utf-8-sig'))
    manifest=read(root/'analysis_inputs.json')
    spectra=read(root/'analysis'/'fft_station_analysis.json')
    evidence={e['sourceId']:e for e in spectra['entries']}
    references={s['id']:s for s in manifest['stations']}
    moves=[]
    for entry in manifest['entries']:
        result=evidence[entry['sourceId']]
        station=references[result['suggestedStationId']]
        weak=not result['matchedStation']['frequencyEvidencePresent']
        label=station['name']+('候选' if weak else '')
        basename=f"{entry['experimentNumber']:02d}-{label}-{entry['sourceId']}"
        entry.update(stationId=station['id'],stationName=station['name'],station=station,
                     stationMatchConfidence=result['matchConfidence'],
                     stationMatchIsWeak=weak,stationEvidence=result['matchedStation'],
                     stationEvidencePath=str(root/'analysis'/f"{entry['experimentNumber']:02d}_{entry['sourceId']}"/'spectral_station_evidence.json'),
                     pbDir=str(root/basename),tfDir=str(root/(basename+'-TF')),
                     tfDigitalCenterHz=station['frequencyHz']-entry['centerFrequencyHz'])
        moves.append(dict(source=entry['originalRunDir'],destination=entry['pbDir']))
    manifest['comparisonConditions']=dict(
        treatment='PB versus TFBlankerV1',stopbandWidthHz=800000,triangleSpanUs=3,
        detectorThreshold='Same frozen ADC amplitude as the corresponding PB run',
        resourceOverride='At most two process workers, single computational thread, invisible figures',
        rfToDigitalCenter='reference station frequency - recording RF center frequency',
        stationIdentity='Frequency and trajectory candidate association, not decoded station identification')
    manifest['excludedSourceId']='HUR'
    manifest['rawRecordingDeletion']=False
    (root/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    (root/'relocation_plan.json').write_text(json.dumps(moves,ensure_ascii=False,indent=2),encoding='utf-8')
    print('Prepared',len(moves),'PB relocations and matched TF configurations.')


if __name__=='__main__':
    main()
