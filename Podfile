platform :ios, '16.0'
# VLCKit plays what Apple's player can't: MPEG-TS live streams, MKV, AC-3/E-AC-3 audio, embedded subtitles.
target 'ShashaIOS' do
  pod 'MobileVLCKit', '~> 3.6.0'
end
post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
      c.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    end
  end
end
