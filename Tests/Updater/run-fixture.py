"""Run real Sparkle against a local HTTP feed in a separate test app/domain."""
import functools
import http.server
import pathlib
import plistlib
import subprocess
import sys
import shutil
import time
import threading
import uuid

root, qa, products = map(pathlib.Path, sys.argv[1:])
app = qa / 'UpdaterQA.app'
feed = qa / 'appcast.xml'
current = qa / 'current.xml'
current.write_bytes((root / 'website/appcast.xml').read_bytes())
feed.write_bytes(current.read_bytes())
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(qa))
with http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler) as server:
    source = plistlib.loads((root / 'Resources/Hannyeong/Info.plist').read_bytes())
    bundle_id = 'com.yeop.HannyeongUpdaterQA.' + uuid.uuid4().hex
    info = {key: value for key, value in source.items() if key.startswith('SU')}
    info.update(CFBundleIdentifier=bundle_id, CFBundleExecutable='UpdaterQA',
                CFBundleName='HannyeongUpdaterQA', CFBundlePackageType='APPL',
                CFBundleShortVersionString='0.4.1', CFBundleVersion='110',
                NSPrincipalClass='NSApplication',
                SUFeedURL=f'http://127.0.0.1:{server.server_port}/appcast.xml',
                NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run([str(root / 'scripts/embed-sparkle.sh'), str(app),
                    str(products / 'Sparkle.framework')], check=True)
    subprocess.run(['codesign', '--force', '--sign',
                    'Developer ID Application: Sang Yeop Lim (79Q5RV23F9)',
                    '--options', 'runtime', '--timestamp', str(app)], check=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        result = subprocess.run([str(app / 'Contents/MacOS/UpdaterQA'), str(feed), str(current)],
                                capture_output=True, text=True, timeout=45)
        print(result.stdout, end='')
        print(result.stderr, end='', file=sys.stderr)
        result.check_returncode()
        assert result.stdout.count('PASS ') == 4, 'Updater QA did not finish all checks'

        # Use a fresh fixture key, not the app's release-signing key in Keychain.
        signer = qa / 'FixtureSigner'
        key = qa / 'fixture-key'
        public_key = subprocess.check_output([str(signer), 'generate', str(key)], text=True).strip()
        identity = 'Developer ID Application: Sang Yeop Lim (79Q5RV23F9)'
        installed = qa / 'installed' / 'UpdaterQA.app'
        target = qa / 'new' / 'UpdaterQA.app'
        installed.parent.mkdir()
        target.parent.mkdir()
        shutil.copytree(app, installed, symlinks=True)
        shutil.copy2(qa / 'InstallQA', installed / 'Contents/MacOS/UpdaterQA')
        journal = qa / 'install-journal.txt'
        journal.write_text('')
        install_info = dict(info, SUPublicEDKey=public_key, QAJournal=str(journal))
        (installed / 'Contents/Info.plist').write_bytes(plistlib.dumps(install_info))
        subprocess.run(['codesign', '--force', '--sign', identity, '--options', 'runtime',
                        '--timestamp', str(installed)], check=True)
        shutil.copytree(installed, target, symlinks=True)
        target_info = dict(install_info, CFBundleVersion='111', CFBundleShortVersionString='0.4.2')
        (target / 'Contents/Info.plist').write_bytes(plistlib.dumps(target_info))
        marker = target / 'Contents/Resources/installed-version.txt'
        marker.parent.mkdir(exist_ok=True)
        marker.write_text('version 111 resource')
        subprocess.run(['codesign', '--force', '--sign', identity, '--options', 'runtime',
                        '--timestamp', str(target)], check=True)
        archive = qa / 'UpdaterQA-111.zip'
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(target),
                        str(archive)], check=True)
        signature = subprocess.check_output([str(signer), 'sign', str(key), str(archive)], text=True).strip()
        feed.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>Local fixture update</title><item><title>Fixture 111</title>
<sparkle:version>111</sparkle:version><sparkle:shortVersionString>0.4.2</sparkle:shortVersionString>
<enclosure url="http://127.0.0.1:{server.server_port}/{archive.name}" type="application/octet-stream"
length="{archive.stat().st_size}" sparkle:edSignature="{signature}"/>
</item></channel></rss>''')
        log_path = qa / 'install-output.log'
        with log_path.open('w') as log:
            process = subprocess.Popen([str(installed / 'Contents/MacOS/UpdaterQA')], stdout=log, stderr=log)
            try:
                code = process.wait(timeout=60)
                deadline = time.monotonic() + 30
                while 'launched 111' not in journal.read_text() and time.monotonic() < deadline:
                    time.sleep(0.1)
                events = journal.read_text()
                print(events, end='')
                assert code == 0, log_path.read_text()
                assert 'launched 111' in events, 'Updated app was not relaunched: ' + log_path.read_text()
                assert all(event in events for event in ['downloaded 111', 'installer-started 111', 'ready 111'])
                assert plistlib.loads((installed / 'Contents/Info.plist').read_bytes())['CFBundleVersion'] == '111'
                assert (installed / 'Contents/Resources/installed-version.txt').read_text() == 'version 111 resource'
                subprocess.run(['codesign', '--verify', '--deep', '--strict', str(installed)], check=True)
                print('PASS signed archive downloaded, verified, installed, and relaunched as version 111')

                # A modified ZIP must be rejected before extraction, preserving the old app.
                negative = qa / 'negative' / 'UpdaterQA.app'
                negative.parent.mkdir()
                shutil.copytree(app, negative, symlinks=True)
                shutil.copy2(qa / 'InstallQA', negative / 'Contents/MacOS/UpdaterQA')
                bad_id = bundle_id + '.negative'
                bad_journal = qa / 'rejection-journal.txt'
                bad_journal.write_text('')
                bad_info = dict(install_info, SUDefaultsDomain=bad_id, QAJournal=str(bad_journal))
                (negative / 'Contents/Info.plist').write_bytes(plistlib.dumps(bad_info))
                subprocess.run(['codesign', '--force', '--sign', identity, '--options', 'runtime',
                                '--timestamp', str(negative)], check=True)
                tampered = qa / 'tampered.zip'
                tampered.write_bytes(archive.read_bytes() + b'changed')
                bad_feed = feed.read_text().replace(archive.name, tampered.name)
                bad_feed = bad_feed.replace(f'length="{archive.stat().st_size}"',
                                            f'length="{tampered.stat().st_size}"')
                feed.write_text(bad_feed)
                try:
                    rejected = subprocess.run([str(negative / 'Contents/MacOS/UpdaterQA')],
                                              capture_output=True, text=True, timeout=60)
                    rejection_events = bad_journal.read_text()
                    print(rejection_events, end='')
                    assert rejected.returncode == 1, rejected.stderr
                    assert 'ERROR SUSparkleErrorDomain 4005' in rejection_events, rejected.stderr
                    assert 'ready ' not in rejection_events, rejected.stderr
                    assert 'signature validation before unarchiving failed' in rejected.stderr, rejected.stderr
                    assert plistlib.loads((negative / 'Contents/Info.plist').read_bytes())['CFBundleVersion'] == '110'
                    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(negative)], check=True)
                    print('PASS tampered archive rejected before extraction; existing app unchanged')
                finally:
                    subprocess.run(['defaults', 'delete', bad_id], check=True)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
    finally:
        server.shutdown()
        subprocess.run(['defaults', 'delete', bundle_id], check=True)
