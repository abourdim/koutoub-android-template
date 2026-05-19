#!/usr/bin/env python3
"""Idempotent camera + microphone wiring for Capacitor Android wrapper.

Injects into android/app/src/main/AndroidManifest.xml:
  - CAMERA, RECORD_AUDIO, MODIFY_AUDIO_SETTINGS permissions
  - uses-feature declarations marking camera/mic as optional
    so cameraless devices can still install the app

Run from a spawned wrapper repo. Also called from manage-*.sh after
`npx cap add android` (when needs_camera: true in books.yaml).
"""
import sys, pathlib

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.').resolve()
MANIFEST = ROOT / 'android/app/src/main/AndroidManifest.xml'

PERMS_BLOCK = '''    <!-- Camera + microphone (getUserMedia / MediaDevices) -->
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />

    <uses-feature android:name="android.hardware.camera"       android:required="false" />
    <uses-feature android:name="android.hardware.camera.front" android:required="false" />
    <uses-feature android:name="android.hardware.microphone"   android:required="false" />

'''

def patch_manifest():
    if not MANIFEST.exists():
        print(f'  · manifest not found at {MANIFEST} (run npx cap add android first)')
        return False
    s = MANIFEST.read_text()
    if 'android.permission.CAMERA' in s:
        print('  · manifest already has CAMERA permission')
        return True
    s = s.replace('    <application', PERMS_BLOCK + '    <application', 1)
    MANIFEST.write_text(s)
    print('  ✓ manifest: CAMERA + RECORD_AUDIO permissions added')
    return True

if __name__ == '__main__':
    print(f'Camera/mic wiring for {ROOT}:')
    patch_manifest()
