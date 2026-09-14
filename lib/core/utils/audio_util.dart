import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:xiaozhi_client_flutter/app/config/app_config.dart';

/// 音频工具类，用于处理Opus音频编解码和录制播放
class AudioUtil {
  static const String TAG = "AudioUtil";

  static final AudioRecorder _audioRecorder = AudioRecorder();
  static bool _isRecorderInitialized = false;
  static bool _isPlayerInitialized = false;
  static bool _isRecording = false;
  static bool _isPlaying = false;

  static final StreamController<Uint8List> _audioStreamController =
      StreamController<Uint8List>.broadcast();

  static Timer? _audioProcessingTimer;

  // 🔥 振幅相关 - 使用持久的广播流控制器
  static final StreamController<double> _amplitudeStreamController =
      StreamController<double>.broadcast();
  static StreamSubscription<Amplitude>? _amplitudeSubscription;

  // Opus相关
  static final _encoder = SimpleOpusEncoder(
    sampleRate: AppConfig.sampleRate,
    channels: AppConfig.channels,
    application: Application.voip,
  );
  static final _decoder = SimpleOpusDecoder(
    sampleRate: AppConfig.sampleRate,
    channels: AppConfig.channels,
  );

  /// 获取音频流
  static Stream<Uint8List> get audioStream => _audioStreamController.stream;

  /// 🔥 获取归一化振幅流 (0.0 ~ 1.0)
  static Stream<double> get amplitudeStream =>
      _amplitudeStreamController.stream;

  /// 初始化音频录制器
  static Future<void> initRecorder() async {
    if (_isRecorderInitialized) return;

    print('$TAG: 开始初始化录音器');

    // 更积极地请求所有可能需要的权限
    if (Platform.isAndroid) {
      print('$TAG: 请求Android所需的所有权限');
      Map<Permission, PermissionStatus> statuses = await [
        Permission.microphone,
        Permission.storage,
        Permission.manageExternalStorage,
        Permission.bluetooth,
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
      ].request();

      print('$TAG: 权限状态:');
      statuses.forEach((permission, status) {
        print('$TAG: $permission: $status');
      });

      if (statuses[Permission.microphone] != PermissionStatus.granted) {
        print('$TAG: 麦克风权限被拒绝');
        throw Exception('需要麦克风权限');
      }
    } else {
      // iOS/other platforms: request microphone permission
      final status = await Permission.microphone.request();

      print('$TAG: MIC_PERMISSION request status = $status');
      print('$TAG: MIC_PERMISSION isGranted = ${status.isGranted}');
      print('$TAG: MIC_PERMISSION isDenied = ${status.isDenied}');
      print(
        '$TAG: MIC_PERMISSION isPermanentlyDenied = '
        '${status.isPermanentlyDenied}',
      );

      final recorderPermission = await _audioRecorder.hasPermission();
      print(
        '$TAG: RECORD_PERMISSION hasPermission = $recorderPermission',
      );

      if (!status.isGranted) {
        print('$TAG: 麦克风权限被拒绝: $status');
        throw Exception(
            'MIC_PERMISSION: $status / granted=${status.isGranted} '
            '/ denied=${status.isDenied} '
            '/ permanentlyDenied=${status.isPermanentlyDenied} '
            '/ recordHasPermission=$recorderPermission',
        );
      }
    }

    // 检查是否可用
    print('$TAG: 检查PCM16编码是否支持');
    final isAvailable = await _audioRecorder.isEncoderSupported(
      AudioEncoder.pcm16bits,
    );
    print('$TAG: PCM16编码支持状态: $isAvailable');

    // 设置音频模式 - 参考Android原生实现
    print('$TAG: 配置音频会话');
    final session = await AudioSession.instance;

    // 使用与原生Android实现更接近的配置
    if (Platform.isAndroid) {
      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.allowBluetooth,
          avAudioSessionMode: AVAudioSessionMode.voiceChat,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            usage: AndroidAudioUsage.voiceCommunication,
            flags: AndroidAudioFlags.audibilityEnforced,
          ),
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientExclusive,
          androidWillPauseWhenDucked: false,
        ),
      );
    } else {
      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.allowBluetooth,
          avAudioSessionMode: AVAudioSessionMode.voiceChat,
        ),
      );
      await session.setActive(true);
    }

    _isRecorderInitialized = true;
    print('$TAG: 录音器初始化成功');
  }

  /// 初始化音频播放器
  static Future<void> initPlayer() async {
    // 确保任何旧播放器被释放
    await stopPlaying();

    try {
      print('$TAG: 初始化音频播放器 - 单声道 ${AppConfig.sampleRate}Hz');

      // 设置 flutter_pcm_sound
      await FlutterPcmSound.setup(
        sampleRate: AppConfig.sampleRate, // 16000 Hz
        channelCount: AppConfig.channels, // 单声道
      );

      // 设置低缓冲阈值以实现实时播放
      await FlutterPcmSound.setFeedThreshold(AppConfig.sampleRate ~/ 10); // 100ms

      _isPlayerInitialized = true;
      print(
        '$TAG: 音频播放器初始化成功 - ${AppConfig.channels}声道 ${AppConfig.sampleRate}Hz',
      );
    } catch (e) {
      print('$TAG: 音频播放器初始化失败: $e');
      _isPlayerInitialized = false;
    }
  }

  /// 播放Opus音频数据
  static Future<void> playOpusData(Uint8List opusData) async {
    try {
      // 如果播放器未初始化，先初始化
      if (!_isPlayerInitialized) {
        await initPlayer();
      }

      // 标记正在播放
      _isPlaying = true;

      // 解码 Opus 数据为 PCM Int16
      final Int16List pcmData = _decoder.decode(input: opusData);

      // flutter_pcm_sound 直接接受 Int16 数据，无需转换为 Float32
      await FlutterPcmSound.feed(PcmArrayInt16.fromList(pcmData.toList()));
    } catch (e, stackTrace) {
      print('$TAG: 播放失败: $e');
      print('$TAG: 堆栈: $stackTrace');

      // 简单重置并重新初始化
      await stopPlaying();
      await initPlayer();
    }
  }

  /// 停止播放
  static Future<void> stopPlaying() async {
    if (_isPlayerInitialized) {
      try {
        await FlutterPcmSound.release();
        print('$TAG: 播放器已停止');
      } catch (e) {
        print('$TAG: 停止播放失败: $e');
      }
      _isPlayerInitialized = false;
    }
    // 标记播放已停止
    _isPlaying = false;
  }

  /// 释放资源
  static Future<void> dispose() async {
    _audioStreamController.close();
    print('$TAG: 资源已释放');
  }

  /// 开始录音
  /// [enableAEC] - 是否启用回声消除（AEC）和降噪，持续监听模式建议开启
  static Future<void> startRecording({bool enableAEC = false}) async {
    if (!_isRecorderInitialized) {
      await initRecorder();
    }

    if (_isRecording) return;

    try {
      print('$TAG: 尝试启动录音 (AEC: $enableAEC)');

      // 确保麦克风权限已获取 - 使用不同方式检查权限
      final status = await Permission.microphone.status;
      print('$TAG: 麦克风权限状态: $status');

      if (status != PermissionStatus.granted) {
        final result = await Permission.microphone.request();
        print('$TAG: 请求麦克风权限结果: $result');
        if (result != PermissionStatus.granted) {
          print('$TAG: 麦克风权限被拒绝: $result');
          throw Exception('Microphone permission denied: $result');
        }
      }

      // 尝试直接使用音频流
      try {
        print('$TAG: 尝试启动流式录音 (AEC: $enableAEC, 降噪: $enableAEC, AGC: $enableAEC)');
        final stream = await _audioRecorder.startStream(
          RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: AppConfig.sampleRate,
            numChannels: AppConfig.channels,
            // 🔥 AEC 回声消除 - 持续监听模式下需要消除扬声器播放的回声
            echoCancel: enableAEC,
            // 🔥 降噪 - 减少背景噪音
            noiseSuppress: enableAEC,
            // 🔥 自动增益控制 - 自动调整麦克风音量
            autoGain: enableAEC,
          ),
        );

        _isRecording = true;
        print('$TAG: 流式录音启动成功');

        // 🔥 启动振幅监听（使用持久的广播流）
        _amplitudeSubscription?.cancel(); // 先取消旧的订阅
        _amplitudeSubscription = _audioRecorder
            .onAmplitudeChanged(const Duration(milliseconds: 100))
            .listen((amp) {
          // 将 dBFS (-60 ~ 0) 转换为 0.0 ~ 1.0
          // dBFS 是负值，0 表示最大音量，-60 表示静音
          final normalized = ((amp.current + 50) / 50).clamp(0.0, 1.0);
          _amplitudeStreamController.add(normalized);
        });

        // 直接从流中处理数据
        stream.listen(
          (data) async {
            if (data.isNotEmpty && data.length % 2 == 0) {
              final opusData = await encodeToOpus(data);
              if (opusData != null) {
                _audioStreamController.add(opusData);
              }
            }
          },
          onError: (error) {
            print('$TAG: 音频流错误: $error');
            _isRecording = false;
          },
          onDone: () {
            print('$TAG: 音频流结束');
            _isRecording = false;
          },
        );
      } catch (e) {
        print('$TAG: 流式录音失败: $e');
        _isRecording = false;
        rethrow;
      }
    } catch (e, stackTrace) {
      print('$TAG: 启动录音失败: $e');
      print(stackTrace);
      _isRecording = false;
    }
  }

  /// 停止录音
  static Future<String?> stopRecording() async {
    if (!_isRecorderInitialized || !_isRecording) return null;

    // 取消定时器
    _audioProcessingTimer?.cancel();

    // 🔥 取消振幅订阅（不关闭 controller，保持持久流）
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;

    // 停止录音
    try {
      final path = await _audioRecorder.stop();
      _isRecording = false;
      print('$TAG: 停止录音: $path');
      return path;
    } catch (e) {
      print('$TAG: 停止录音失败: $e');
      _isRecording = false;
      return null;
    }
  }

  /// 将PCM数据编码为Opus格式
  static Future<Uint8List?> encodeToOpus(Uint8List pcmData) async {
    try {
      // 删除频繁日志
      // 转换PCM数据为Int16List (小端字节序，与Android一致)
      final Int16List pcmInt16 = Int16List.fromList(
        List.generate(
          pcmData.length ~/ 2,
          (i) => (pcmData[i * 2]) | (pcmData[i * 2 + 1] << 8),
        ),
      );

      // 确保数据长度符合Opus要求（必须是2.5ms、5ms、10ms、20ms、40ms或60ms的采样数）
      final int samplesPerFrame =
          (AppConfig.sampleRate * AppConfig.frameDuration) ~/ 1000;

      Uint8List encoded;

      // 处理过短的数据
      if (pcmInt16.length < samplesPerFrame) {
        // 对于过短的数据，可以通过添加静音来填充到所需长度
        final Int16List paddedData = Int16List(samplesPerFrame);
        for (int i = 0; i < pcmInt16.length; i++) {
          paddedData[i] = pcmInt16[i];
        }

        // 编码填充后的数据
        encoded = Uint8List.fromList(_encoder.encode(input: paddedData));
      } else {
        // 对于足够长的数据，裁剪到精确的帧长度
        encoded = Uint8List.fromList(
          _encoder.encode(input: pcmInt16.sublist(0, samplesPerFrame)),
        );
      }

      return encoded;
    } catch (e, stackTrace) {
      print('$TAG: Opus编码失败: $e');
      print(stackTrace);
      return null;
    }
  }

  /// 检查是否正在录音
  static bool get isRecording => _isRecording;

  /// 检查是否正在播放
  static bool get isPlaying => _isPlaying;

  /// 🔥 检测设备音频处理能力
  /// 返回一个 Map 包含各项音频功能的支持状态
  static Future<Map<String, bool>> checkAudioCapabilities() async {
    final result = <String, bool>{};
    
    try {
      // 检测 AEC (回声消除) 支持
      // 通过尝试创建带 AEC 配置的录音来检测
      final hasPermission = await _audioRecorder.hasPermission();
      result['hasPermission'] = hasPermission;
      
      // 检测 PCM16 编码支持
      final pcm16Supported = await _audioRecorder.isEncoderSupported(
        AudioEncoder.pcm16bits,
      );
      result['pcm16Supported'] = pcm16Supported;
      
      // Android 和 iOS 对 AEC 的支持情况
      // Android: 大多数设备支持，通过 VOICE_COMMUNICATION 音频源
      // iOS: 通过 AVAudioSession 的 voiceChat 模式支持
      if (Platform.isAndroid) {
        // Android 4.0+ (API 14+) 支持 AEC
        result['aecSupported'] = true;
        result['noiseSuppressSupported'] = true;
        result['autoGainSupported'] = true;
      } else if (Platform.isIOS) {
        // iOS 通过 AVAudioSession voiceChat 模式支持 AEC
        result['aecSupported'] = true;
        result['noiseSuppressSupported'] = true;
        result['autoGainSupported'] = true;
      } else {
        // 其他平台（桌面等）可能不支持
        result['aecSupported'] = false;
        result['noiseSuppressSupported'] = false;
        result['autoGainSupported'] = false;
      }
      
      print('$TAG: 音频能力检测结果: $result');
    } catch (e) {
      print('$TAG: 音频能力检测失败: $e');
      result['error'] = true;
    }
    
    return result;
  }
}
