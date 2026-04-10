Pod::Spec.new do |s|
  s.name             = 'CansConnect'
  s.version          = '1.0.0'
  s.summary          = 'CansConnect local development for React Native'
  s.homepage         = 'https://cans.cc'
  s.license          = { :type => 'MIT' }
  s.author           = { 'CANScall' => 'near@canscloud.com' }
  s.source           = { :path => '.' }

  s.platform         = :ios, '15.1'
  
  s.source_files     = '**/*.{h,m,swift}'
  s.resources = ['**/linphonerc-factory']
  s.exclude_files    = [
      'DemoApp/**/*',
      'msgNotificationContent/**/*',
      'msgNotificationService/**/*'
    ]
  
  s.header_dir       = 'CansConnect'
  
  s.dependency 'linphone-sdk', '~> 5.2'
  
  # 💡 หมายเหตุ: หากตอนรัน pod install แล้วมันฟ้องว่าหา 'core' ไม่เจอ
  # ให้ลองเปลี่ยนเป็น 'linphone-sdk/swift' หรือ 'linphone-sdk/default' แทนครับ
  
  s.pod_target_xcconfig = { 
    'DEFINES_MODULE' => 'YES',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_XCFRAMEWORKS_BUILD_DIR}/linphone-sdk/**"',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES'
  }
  
  s.swift_version = '5.0'
end