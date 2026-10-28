#!/usr/bin/env python3
"""Feste PCM-Gates für libVLC 3.0.20/3.0.24; keine Korrelation oder Zeitkorrektur.

Aufruf im Linux-Buildimage mit Qt6Core, libvlc, FFmpeg und g++:
    python3 linux/tests/timeshift_verify.py --work /tmp/mucke-timeshift-gate
--case schränkt den Lauf auf einen Namen ein. --keep-pcm behält große Rohdaten.
Die Ergebnisse enthalten Hashes, Längen, erste Samples, Gesamtfehler und Clockwerte.
"""
import argparse
import array
import hashlib
import json
import math
import pathlib
import shlex
import statistics
import subprocess

CASES = [
    ('mp3-cbr-48000', 'mp3', 48000, False),
    ('mp3-id3-48000', 'mp3', 48000, False),
    ('mp3-id3-44100', 'mp3', 44100, False),
    ('mp3-xing-48000', 'mp3', 48000, False),
    ('mp3-xing-44100', 'mp3', 44100, False),
    ('mp3-vbr-48000', 'mp3', 48000, True),
    ('mp3-cbr-44100', 'mp3', 44100, False),
    ('mp3-vbr-44100', 'mp3', 44100, True),
    ('mp3-cbr-32000', 'mp3', 32000, False),
    ('mp3-cbr-24000', 'mp3', 24000, False),
    ('mp3-vbr-22050', 'mp3', 22050, True),
    ('mp3-cbr-16000', 'mp3', 16000, False),
    ('aac-lc-48000', 'aac', 48000, False),
    ('aac-lc-44100', 'aac', 44100, False),
    ('aac-lc-32000', 'aac', 32000, False),
    ('aac-lc-24000', 'aac', 24000, False),
    ('aac-lc-22050', 'aac', 22050, False),
    ('aac-lc-16000', 'aac', 16000, False),
]


def run(args):
    subprocess.run([str(x) for x in args], check=True, timeout=50)


def frame_index(data, codec):
    offset = 0
    if data.startswith(b'ID3'):
        h = data[:10]
        assert len(h)==10 and not any(x&128 for x in h[6:10])
        offset = 10 + (h[6]<<21) + (h[7]<<14) + (h[8]<<7) + h[9]
        assert offset<=65536
    result = []
    while offset < len(data):
        h = data[offset:offset+7]
        if codec == 'mp3':
            assert h[0] == 255 and h[1] & 0xe0 == 0xe0
            version = (h[1] >> 3) & 3
            rate = [44100, 48000, 32000][(h[2] >> 2) & 3] // (1 if version == 3 else 2 if version == 2 else 4)
            rates = [0,32,40,48,56,64,80,96,112,128,160,192,224,256,320] if version == 3 else [0,8,16,24,32,40,48,56,64,80,96,112,128,144,160]
            size = (144 if version == 3 else 72) * rates[h[2] >> 4] * 1000 // rate + ((h[2] >> 1) & 1)
            samples = 1152 if version == 3 else 576
        else:
            assert h[0] == 255 and h[1] & 0xf6 == 0xf0 and h[2] >> 6 == 1
            rate = [96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350][(h[2] >> 2) & 15]
            size = ((h[3] & 3) << 11) | (h[4] << 3) | (h[5] >> 5)
            samples = 1024
        assert size > 7 and offset+size <= len(data)
        result.append((offset, samples, rate))
        offset += size
    assert offset == len(data)
    return result


def read_pcm(path):
    result = array.array('h')
    result.frombytes(path.read_bytes())
    return result


def tone(samples, rate, start, frequency):
    offset = int(round(start*rate))*2
    window = samples[offset:offset+int(rate*.1)*2:2]
    if len(window) < rate*.09:
        return None
    real = sum(x * math.cos(2*math.pi*frequency*i/rate) for i, x in enumerate(window))
    imaginary = sum(x * math.sin(2*math.pi*frequency*i/rate) for i, x in enumerate(window))
    return (real*real+imaginary*imaginary)**.5 / len(window)


def clock_report(metadata):
    first_pts = metadata['clock'][0]['pts']
    samples = [((row['now']-first_pts)/1e6, row['vlcTime']/1000) for row in metadata['playbackClock']]
    # get_time wird in VLC ungefähr alle 300 ms fortgeschrieben. Die letzte
    # Drainphase bleibt stehen und ist kein gültiger Wiedergabezeitpunkt.
    moving = [(actual, vlc) for actual, vlc in samples if 1 < actual < 4 and vlc > 0]
    errors = [vlc-actual for actual, vlc in moving]
    return dict(minError=min(errors), maxError=max(errors), medianError=statistics.median(errors), samples=len(errors))


def build(root, work):
    flags = shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','Qt6Core','libvlc'],text=True))
    version = subprocess.check_output(['pkg-config','--modversion','libvlc'],text=True).strip()
    assert version in ('3.0.20','3.0.24'), f'ungeprüfte libVLC-Version: {version}'
    run(['g++','-std=c++17','-O2','-fPIC','-Wall','-Wextra','-Werror',root/'tests/timeshift_pcm.cpp',root/'src/media/timeshift.cpp','-I'+str(root/'src'),*flags,'-o',work/'pcm'])
    return version


def case(root, work, spec, keep, args):
    name, codec, rate, vbr = spec
    directory = work/name
    directory.mkdir(exist_ok=True)
    source = (args.fixtures/name if args.fixtures else directory)/('marker.'+codec)
    # PNS verwendet Decoder-Zufallszustand; diese deterministische Fixture prüft
    # die Startgrenze mit identischen Samples statt statistischem Rauschen.
    encoder = ['-c:a','libmp3lame', '-q:a','3'] if codec=='mp3' and vbr else ['-c:a','libmp3lame','-b:a','128k'] if codec=='mp3' else ['-c:a','aac','-profile:a','aac_low','-aac_pns','0','-b:a','96k']
    container = (['-write_xing','1','-id3v2_version','4','-metadata','title=PCM boundary gate'] if '-xing-' in name else ['-write_xing','0','-id3v2_version','4','-metadata','title=PCM boundary gate'] if '-id3-' in name else ['-write_xing','0','-id3v2_version','0']) if codec=='mp3' else ['-f','adts']
    if not args.fixtures:
        run(['ffmpeg','-v','error','-f','lavfi','-i',f'sine=frequency=440:sample_rate={rate}:duration=6','-f','lavfi','-i',f'sine=frequency=880:sample_rate={rate}:duration=6','-filter_complex','[0:a][1:a]concat=n=2:v=0:a=1',*encoder,*container,'-y',source])
    data = source.read_bytes()
    index = frame_index(data,codec)
    frame_samples = index[0][1]
    duration = frame_samples/rate
    marker_frame = math.ceil(6/duration)
    # Metadatenwechsel mitten im Frame: dessen erste Bytes behalten 440.
    marker_offset = index[marker_frame][0] + 2
    demux = 'mpga' if codec=='mp3' else 'aac'
    correction = (1 if rate in (32000,16000) else 2) if codec=='mp3' else (1 if rate==32000 else 0)
    baseline_path = directory/'baseline.pcm'
    run([args.binary,source,baseline_path,'file',demux])
    baseline = read_pcm(baseline_path)
    baseline_metadata = json.loads(pathlib.Path(str(baseline_path)+'.json').read_text())
    assert not baseline_metadata['formatChanges']
    if baseline_metadata['decodedRate'] != rate:
        assert codec=='aac' and rate<32000, 'unerwartete Decoderfrequenz'
        actual_rate = baseline_metadata['decodedRate']
        actual_correction = 1 if actual_rate==32000 else 0
        rejected = None if args.probe else subprocess.run([str(x) for x in [args.binary,source,directory/'rejected.pcm','buffer',demux,'4',str(actual_rate),str(actual_correction),str(marker_offset)]],timeout=50)
        report = dict(case=name,codec=codec,coreSampleRate=rate,decoderSampleRate=actual_rate,supported=False,reason='Decoderfrequenz weicht vom ADTS-Kern ab; konservativ gesperrt.',passed=args.probe or rejected.returncode==11)
        (directory/'report.json').write_text(json.dumps([report],indent=2)+'\n')
        print(json.dumps(report),flush=True)
        if not keep: baseline_path.unlink()
        return [report]
    if '-xing-' in name and not args.probe:
        rejected = subprocess.run([str(x) for x in [args.binary,source,directory/'rejected.pcm','buffer',demux,'0',str(rate),str(correction),str(marker_offset)]],timeout=50)
        report = dict(case=name,codec=codec,sampleRate=rate,supported=False,reason='Xing/Info-Gapless-Dateiindex: Live-Frameprofil nicht anwendbar.',passed=rejected.returncode==11)
        (directory/'report.json').write_text(json.dumps([report],indent=2)+'\n')
        print(json.dumps(report),flush=True)
        if not keep: baseline_path.unlink()
        return [report]
    reports = []
    for target in args.target or [2,4,6,8]:
        outfile = directory/f'buffer-{target}.pcm'
        warm_frames = math.ceil(1/duration - .000001)
        output_frame = max(warm_frames, math.floor(target/duration + .000001))
        input_frame = output_frame - warm_frames
        if args.probe:
            cut = directory/f'probe-{target}.cut'
            cut.write_bytes(data[index[input_frame][0]:])
            skip_ms = ((output_frame-input_frame)+correction)*duration*1000
            skip_ms = math.ceil(skip_ms-.000001) if codec=='aac' else math.floor(skip_ms+.000001)
            run([args.binary,cut,outfile,'callback',demux,':file-caching=1000',f':audio-desync=-{skip_ms}'])
            cut.unlink()
        else:
            mode = 'initial' if args.initial_live else 'buffer'
            initial_count = warm_frames + math.ceil(3/duration - .000001)
            initial_bytes = index[initial_count][0]
            run([args.binary,source,outfile,mode,demux,str(target),str(rate),str(correction),str(marker_offset),str(initial_bytes)])
        actual = read_pcm(outfile)
        metadata = json.loads(pathlib.Path(str(outfile)+'.json').read_text())
        if args.probe:
            metadata['inputStart'] = input_frame*duration
            metadata['outputStart'] = output_frame*duration
        expected = baseline[output_frame*frame_samples*2:]
        common = min(len(actual),len(expected))
        differences = [actual[i]-expected[i] for i in range(common)]
        peak = max(abs(x) for x in differences)
        rms = (sum(x*x for x in differences)/common)**.5
        first_peak = max(abs(x) for x in differences[:2048])
        clock = clock_report(metadata)
        tones = {}
        for position, expected_tone in [(5.5,440),(6.5,880)]:
            if position < metadata['outputStart']:
                continue
            strengths = [tone(actual,rate,position-metadata['outputStart'],f) for f in [440,880]]
            assert all(x is not None for x in strengths)
            tones[str(position)] = dict(expected=expected_tone, amplitude440=strengths[0], amplitude880=strengths[1])
        passed = len(actual)==len(expected) and peak<=1 and first_peak<=1 and metadata['decodedRate']==rate and not metadata['formatChanges']
        passed = passed and abs(metadata['outputStart']-output_frame*duration)<1/rate and metadata['outputStart']-metadata['inputStart'] >= 1-1/rate
        passed = passed and (args.probe or (metadata['titleBefore']=='440' and metadata['titleAfter']=='880'))
        passed = passed and clock['minError']>-.45 and clock['maxError']<.12
        passed = passed and all((v['amplitude440'] if v['expected']==440 else v['amplitude880']) > 10*(v['amplitude880'] if v['expected']==440 else v['amplitude440']) for v in tones.values())
        report = dict(case=name,target=target,probe=args.probe,firstReadyLive=metadata['firstReadyLive'],firstReadyOldest=metadata['firstReadyOldest'],codec=codec,sampleRate=rate,correctionFrames=correction,inputStart=metadata['inputStart'],outputStart=metadata['outputStart'],expectedFrames=len(expected)//2,actualFrames=len(actual)//2,peakLSB=peak,rmsLSB=rms,firstPeakLSB=first_peak,firstSamples=list(actual[:16]),expectedFirstSamples=list(expected[:16]),pcmSHA256=hashlib.sha256(outfile.read_bytes()).hexdigest(),clock=clock,tones=tones,passed=passed)
        reports.append(report)
        print(json.dumps(report),flush=True)
        (directory/'report.json').write_text(json.dumps(reports,indent=2)+'\n')
        if not keep: outfile.unlink()
    if not keep: baseline_path.unlink()
    return reports


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work',type=pathlib.Path,required=True)
    parser.add_argument('--case',action='append')
    parser.add_argument('--keep-pcm',action='store_true')
    parser.add_argument('--target',type=float,action='append',help='einzelner Startpunkt für kurze Probes')
    parser.add_argument('--initial-live',action='store_true',help='Reader beim ersten Ready-Zustand erzeugen; mit --target 0 verwenden')
    parser.add_argument('--no-build',action='store_true',help='vorhandene portable Binary verwenden')
    parser.add_argument('--binary',type=pathlib.Path,help='Pfad zur PCM-Binary')
    parser.add_argument('--fixtures',type=pathlib.Path,help='vorab erzeugte Case-Ordner; benötigt kein FFmpeg')
    parser.add_argument('--probe',action='store_true',help='reine Callback-Probe auch für noch nicht freigegebene VLC-Versionen')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    work = args.work.resolve(); work.mkdir(parents=True,exist_ok=True)
    if args.fixtures: args.fixtures = args.fixtures.resolve()
    if not args.no_build: build(root,work)
    args.binary = (args.binary or work/'pcm').resolve()
    version = subprocess.check_output([str(args.binary),'--version'],text=True).strip()
    reports = []
    for spec in CASES:
        if not args.case or spec[0] in args.case:
            reports += case(root,work,spec,args.keep_pcm,args)
    summary = dict(libvlc=version,probe=args.probe,passed=all(x['passed'] for x in reports),reports=reports)
    (work/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    assert reports and summary['passed'], 'PCM-/Clock-Gate fehlgeschlagen; report.json/summary.json prüfen'

if __name__ == '__main__': main()
