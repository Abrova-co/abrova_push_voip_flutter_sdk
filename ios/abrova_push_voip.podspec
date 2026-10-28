Pod::Spec.new do |s|
  s.name             = 'abrova_push_voip'
  s.version          = '0.1.2'
  s.summary          = 'VoIP call handling add-on for AbrovaPush push notifications.'
  s.description      = <<-DESC
VoIP call handling add-on for AbrovaPush push notifications.
Thin wrapper around native AbrovaPushVoip SDK.
Provides native incoming call UI using CallKit on iOS.
                       DESC
  s.homepage         = 'https://abrova.ir/cloud/abrova-push'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Abrova' => 'support@abrova.ir' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }

  # Native AbrovaPush VoIP SDK (CocoaPods)
  s.dependency 'AbrovaPushVoip', '~> 0.1'
end
