from pathlib import Path

root = Path("source")
session = root / "lib/core/session_manager.dart"
processor = root / "lib/modules/audio/audio_processor.dart"

s = session.read_text()

old = """  void _onAudioData(Uint8List data) {
    if (_currentState != DeviceState.speaking) {
      return;
    }
    AudioService.instance.playOpusAudio(data);
  }"""
new = """  void _onAudioData(Uint8List data) {
    if (_currentSessionId == null) {
      return;
    }
    AudioService.instance.playOpusAudio(data);
  }"""
if old not in s:
    raise SystemExit("session_manager.dart: _onAudioData block not found")
s = s.replace(old, new, 1)

old = """      // 【修正】不在会话开始时发送 listen start
      // listen start 由 audio_processor 在 VAD 检测到语音开始时发送
      // 这样每次对话（而不是每次会话）都有独立的 listen start/stop

      // 启用 VAD（录音已在 initialize 时启动）
      AudioService.instance.enableVad(true);"""
new = """      // Start VAD/transport immediately. AudioProcessor opens
      // the server listen state without waiting for local speech detection.
      await AudioService.instance.enableVad(true);"""
if old not in s:
    raise SystemExit("session_manager.dart: _startListening block not found")
s = s.replace(old, new, 1)
session.write_text(s)

p = processor.read_text()

old = """    if (enable && !wasEnabled) {
      _wasSpeaking = false;  // 从禁用变为启用时重置状态
      await RecordService.instance.resumeRecording();
      AppLogger.d('VAD enabled (was disabled), _wasSpeaking reset to false');
    } else if (enable && wasEnabled) {
      // VAD 已经在工作，不重置状态
      AppLogger.d('VAD already enabled, keeping _wasSpeaking=$_wasSpeaking');
    } else {
      AppLogger.d('VAD disabled');
    }"""
new = """    if (enable && !wasEnabled) {
      _wasSpeaking = false;
      await RecordService.instance.resumeRecording();

      if (ProtocolService.instance.isConnected) {
        ProtocolService.instance.sendStartListening(mode: 'auto');
      }

      AppLogger.d('VAD enabled, server listen started');
    } else if (enable && wasEnabled) {
      AppLogger.d('VAD already enabled, keeping transport alive');
    } else if (!enable && wasEnabled) {
      if (ProtocolService.instance.isConnected) {
        ProtocolService.instance.sendStopListening();
      }
      AppLogger.d('VAD disabled, server listen stopped');
    } else {
      AppLogger.d('VAD disabled');
    }"""
if old not in p:
    raise SystemExit("audio_processor.dart: enableVad block not found")
p = p.replace(old, new, 1)

start = p.index("    // ========== 4. VAD 状态检测与发送逻辑 ==========")
end = p.index("  int _totalFramesSent = 0;", start)
replacement = """    // ========== 4) Transport-level microphone streaming ==========
    // Keep KWS/VAD processing for wake-word/UI behavior, but do not
    // require VoiceEngine.isSpeaking before sending microphone audio.
    if (_vadEnabled) {
      if (_pcmBuffer.length + dataFor16k.length > _maxPcmBufferSize) {
        AppLogger.w('PCM buffer overflow (' + _pcmBuffer.length.toString() + ' bytes), clearing');
        _pcmBuffer.clear();
      }

      _pcmBuffer.addAll(dataFor16k);

      int framesSent = 0;
      while (_pcmBuffer.length >= _opusBytesPerFrame) {
        _encodeAndSend();
        framesSent++;
      }

      if (framesSent > 0) {
        _totalFramesSent += framesSent;
        if (_totalFramesSent % 10 == 0) {
          AppLogger.d('已发送 ' + _totalFramesSent.toString() + ' 帧音频');
        }
      }
    }

"""
p = p[:start] + replacement + p[end:]
processor.write_text(p)

print("VOICE TRANSPORT PATCH APPLIED")
print("MCP code untouched")
