#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
PHONE_REPO="${1:?iPhone-Repo mit V3-Unterstützung als Argument angeben}"
OUT="${EXCHANGE_TEST_OUTPUT:-build/tests/exchange-interop}"
mkdir -p "$OUT"
SDK="$(xcrun --show-sdk-path)"
MAC_SOURCES=(Safety Models StationSelection SongRecognition SongHistory HistoryFilter BookmarkStore ExchangeCodec ExchangeMerge ExchangeTransaction LibraryExchangeStorage)
mac_files=()
for name in "${MAC_SOURCES[@]}"; do mac_files+=("Sources/$name.swift"); done
swiftc -parse-as-library -target arm64-apple-macos14.2 -sdk "$SDK" -module-cache-path "$OUT/module-cache" \
  "${mac_files[@]}" Tests/ExchangeInteropHarness.swift -o "$OUT/mac-codec"
PHONE_SOURCES=(Models StationCollection SongRecognition SongHistory BookmarkStore ExchangeCodec ExchangeMerge ExchangeTransaction LibraryExchangeStorage ExchangeURLPolicy)
phone_files=()
for name in "${PHONE_SOURCES[@]}"; do phone_files+=("$PHONE_REPO/BabyMucke/$name.swift"); done
swiftc -parse-as-library -target arm64-apple-macos14.2 -sdk "$SDK" -module-cache-path "$OUT/module-cache" \
  "${phone_files[@]}" Tests/ExchangeInteropHarness.swift -o "$OUT/phone-codec"
for version in 1 2 3; do
  for origin in mac phone; do
    if [[ "$origin" == mac ]]; then recipient=phone; else recipient=mac; fi
    source_file="$OUT/$origin-v$version.json"
    middle_file="$OUT/$origin-$recipient-v$version.json"
    final_file="$OUT/$origin-$recipient-$origin-v$version.json"
    "$OUT/$origin-codec" generate "$source_file" "$version"
    "$OUT/$recipient-codec" reencode "$source_file" "$middle_file"
    "$OUT/$origin-codec" reencode "$middle_file" "$final_file"
    "$OUT/$origin-codec" verify "$final_file" "$source_file"
  done
done
"$OUT/mac-codec" context-conflict "$OUT/mac-v3.json"
"$OUT/phone-codec" context-conflict "$OUT/mac-v3.json"
python3 - "$OUT" <<'PY'
from pathlib import Path
import json,subprocess,sys
root=Path(sys.argv[1])
for version in [1,2,3]:
 for origin,recipient in [('mac','phone'),('phone','mac')]:
  before=json.loads((root/f'{origin}-v{version}.json').read_text())
  after=json.loads((root/f'{origin}-{recipient}-{origin}-v{version}.json').read_text())
  assert before==after and after['formatVersion']==version
  assert after['stations'][0]['favorite'] and after['groups'][0]['stationIDs']==[after['stations'][0]['id']]
  assert all(b['heardAt']=='2026-10-14T17:46:40.123Z' for b in after['bookmarks'])
  if version==3:
   direct,buffered=after['bookmarks'][1:]
   assert direct['recognition']['listening']=={'outputID':'88888888-8888-4888-8888-888888888888','revision':0}
   assert buffered['recognition']['listening']=={'outputID':'88888888-8888-4888-8888-888888888888','revision':18446744073709551615,'position':123.456789,'receivedAt':'2026-10-14T17:45:09.998Z'}
base=json.loads((root/'mac-v3.json').read_text())
invalid=[]
for version in [1,2,4,99]:
 value=json.loads(json.dumps(base));value['formatVersion']=version;invalid.append(value)
for key,value in [('outputID','bad'),('revision',-1),('revision',1.5),('revision',2**64),('position',-1),('position','NaN'),('receivedAt','2026-02-30T12:00:00Z'),('receivedAt',None),('position',None)]:
 doc=json.loads(json.dumps(base));context=doc['bookmarks'][2]['recognition']['listening'];context[key]=value;invalid.append(doc)
for i,doc in enumerate(invalid):
 fixture=root/f'invalid-{i}.json';fixture.write_text(json.dumps(doc))
 for platform in ['mac','phone']: subprocess.run([str((root/f'{platform}-codec').resolve()),'reject',str(fixture)],check=True)
(root/'result.json').write_text(json.dumps({'roundtrips':6,'versions':[1,2,3],'productionCodecs':['mac','phone'],'invalidFilesPerCodec':len(invalid),'fullUInt64Revision':True,'contextOnlyConflictsVisible':True},indent=2))
print('Beide Produktions-Codecs: sechs V1/V2/V3-Roundtrips, volle Hörkontexte, Mixidentität und Fehlerfälle bestanden.')
PY
