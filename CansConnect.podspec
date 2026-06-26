Pod::Spec.new do |s|
  s.name             = 'CansConnect'
  s.version          = '1.0.5'
  s.summary          = 'CansConnect ios sdk development for CANScall'
  s.homepage         = 'https://cans.cc'
  s.license          = { :type => 'MIT' }
  s.author           = { 'CANScall' => 'near@canscloud.com' }
  s.source           = { :git => 'https://github.com/cans-communication/canscloud-ios-framework.git', :tag => s.version.to_s }

  s.platform         = :ios, '15.1'

  s.source_files     = 'CansConnect/**/*.{h,m,swift}'
  s.resources = ['CansConnect/**/linphonerc-factory']
  s.exclude_files    = [
      'DemoApp/**/*',
      'msgNotificationContent/**/*',
      'msgNotificationService/**/*'
    ]

  s.header_dir       = 'CansConnect'

  s.dependency 'linphone-sdk'

  s.static_framework = true

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_XCFRAMEWORKS_BUILD_DIR}/linphone-sdk/**"',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES'
  }

  s.swift_version = '5.0'
end
