Pod::Spec.new do |s|
  s.name             = 'better_native_video_player'
  s.version          = '0.3.3'
  s.summary          = 'A Flutter plugin for native video playback on iOS and Android'
  s.description      = <<-DESC
A Flutter plugin that provides native video player using AVPlayerViewController on iOS
and ExoPlayer (Media3) on Android, with HLS support, Picture-in-Picture, fullscreen playback,
and Now Playing integration.
                       DESC
  s.homepage         = 'https://github.com/DaniKemper010/native-video-player'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Dani Kemper' => 'dani@plugandpay.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
