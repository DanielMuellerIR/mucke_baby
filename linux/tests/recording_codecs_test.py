#!/usr/bin/env python3
import hashlib,json,pathlib,subprocess,sys,tempfile

def main():
    probe=str(pathlib.Path(sys.argv[1]).resolve(strict=True))
    reports=[]
    cases=[('mp3','libmp3lame','mp3'),('aac','aac','aac'),('ogg','libvorbis','vorbis'),('opus','libopus','opus'),('flac','flac','flac')]
    with tempfile.TemporaryDirectory(prefix='mucke-recording-codecs-') as temporary:
        root=pathlib.Path(temporary)
        for extension,encoder,codec in cases:
            source=root/('source.'+extension)
            subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-n','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','6','-c:a',encoder,str(source)],check=True)
            before=hashlib.sha256(source.read_bytes()).hexdigest()
            completed=subprocess.run([probe,str(source),str(root/extension)],text=True,capture_output=True,check=True,timeout=15)
            result=json.loads(completed.stdout)
            info=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',result['file']],text=True))
            assert info['streams'][0]['codec_name']==codec
            pcm=subprocess.check_output(['ffmpeg','-v','error','-i',result['file'],'-f','f32le','-ac','1','-ar','48000','-'],timeout=15)
            assert len(pcm)>48000*4*5
            assert hashlib.sha256(source.read_bytes()).hexdigest()==before
            reports.append({'codec':codec,'encodedBytes':result['bytes'],'exactAudioBytes':result['exactAudioBytes'],'decodedSamples':len(pcm)//4,'sourceUnchanged':True})
    print(json.dumps({'passed':True,'reports':reports},indent=2))
if __name__=='__main__':main()
