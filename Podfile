source 'https://cdn.cocoapods.org/'
platform :ios, '26.0'
install! 'cocoapods', :deterministic_uuids => true

target 'Luma' do
  use_frameworks! :linkage => :static
  pod 'MobileVLCKit', '3.7.3'

  target 'LumaTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
      config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    end
  end
end
