"""Configure a Flutter-generated iOS runner. Does not sign or distribute an app."""
from pathlib import Path
import plistlib

info = Path('ios/Runner/Info.plist')
with info.open('rb') as stream:
    data = plistlib.load(stream)
data.update({
    'CFBundleDisplayName': 'Snake Catcher',
    'NSCameraUsageDescription': 'تستخدم الكاميرا لكشف الحركة وتسجيلها أثناء تشغيل المراقبة.',
    'NSMicrophoneUsageDescription': 'يستخدم الميكروفون لتسجيل الصوت مع فيديو الحركة.',
    'NSPhotoLibraryUsageDescription': 'يستخدم الوصول للصور لحفظ مقاطع الحركة في معرض الهاتف.',
    'NSPhotoLibraryAddUsageDescription': 'يحفظ مقاطع الحركة في ألبوم Snake Catcher.',
})
with info.open('wb') as stream:
    plistlib.dump(data, stream, sort_keys=False)

podfile = Path('ios/Podfile')
if podfile.exists():
    source = podfile.read_text()
    anchor = 'flutter_additional_ios_build_settings(target)'
    addition = '''
    target.build_configurations.each do |config|
      config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ['$(inherited)']
      config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] += [
        'PERMISSION_CAMERA=1',
        'PERMISSION_MICROPHONE=1',
        'PERMISSION_PHOTOS=1',
        'PERMISSION_PHOTOS_ADD_ONLY=1'
      ]
    end
'''
    if anchor not in source:
        raise RuntimeError('Expected Flutter Podfile hook was not found')
    if 'PERMISSION_CAMERA=1' not in source:
        podfile.write_text(source.replace(anchor, anchor + addition))
