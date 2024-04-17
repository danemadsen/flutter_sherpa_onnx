import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx_dart/src/sherpa_onnx_isolate.dart';
import 'package:sherpa_onnx_dart/src/word_transcription.dart';

///
/// An interface for creating/using/destroying a sherpa-onnx Recognizer/Stream
/// that runs on a background isolate.
/// Calling the constructor only sets up the background isolate; you will need
/// to call [createRecognizer], [createStream], then [acceptWaveform] to start
/// processing audio data.
///
class SherpaOnnx {
  Stream<ASRResult> get result => _resultController.stream;
  final _resultController = StreamController<ASRResult>.broadcast();

  Future<Isolate>? _runner;

  Future<bool> get ready async {
    if (_runner == null) {
      return false;
    }
    await _runner;
    return true;
  }

  final _createdRecognizerPort = ReceivePort();
  late final Stream _createdRecognizerPortStream =
      _createdRecognizerPort.asBroadcastStream();
  final _createdStreamPort = ReceivePort();
  Completer? _createdStream;

  final _setupPort = ReceivePort();
  bool _killed = false;
  final _resultPort = ReceivePort();

  late SendPort _dataPort;
  late SendPort _createRecognizerPort;
  late SendPort _killRecognizerPort;
  late SendPort _createStreamPort;
  late SendPort _shutdownPort;
  final _isolateSetupComplete = Completer();

  late final StreamSubscription _setupListener;
  late final StreamSubscription _resultListener;
  late final StreamSubscription _createdStreamListener;

  SherpaOnnx() {
    _setupListener = _setupPort.listen((msg) {
      _dataPort = msg[0];
      _createRecognizerPort = msg[1];
      _killRecognizerPort = msg[2];
      _createStreamPort = msg[3];
      _shutdownPort = msg[4];
      _isolateSetupComplete.complete(true);
    });

    _resultListener = _resultPort.listen(_onResult);

    _createdStreamListener = _createdStreamPort.listen((success) {
      try {
        _createdStream!.complete(success as bool);
      } catch (err) {
        print(err);
      }
    });

    _runner = Isolate.spawn(SherpaOnnxIsolate.create, [
      _setupPort.sendPort,
      _createdRecognizerPort.sendPort,
      _createdStreamPort.sendPort,
      _resultPort.sendPort
    ]);
  }

  void _onResult(dynamic result) {
    var resultMap = json.decode(result);

    bool isFinal = resultMap["is_endpoint"] == true;

    if (isFinal) {
      if (resultMap["text"].isNotEmpty) {
        var numTokens = resultMap["tokens"].length;
        var words = <WordTranscription>[];
        for (int i = 0; i < numTokens; i++) {
          words.add(WordTranscription(
              resultMap["tokens"][i], resultMap["timestamps"][i], -1));
        }
        _resultController.add(ASRResult(isFinal, words));
      }
    } else {
      if (resultMap["text"].isNotEmpty) {
        _resultController.add(ASRResult(
            isFinal, [WordTranscription(resultMap["text"], null, null)]));
      }
    }
  }

  Future decodeBuffer() async {
    throw Exception("TODO");
  }

  bool _hasRecognizer = false;

  ///
  /// Creates a recognizer using the tokens, encoder, decoder and joiner at the specified paths.
  /// [sampleRate] is the sample rate of the PCM-encoded data that will be passed into [acceptWaveform].
  /// When [acceptWaveform] is called, the audio data is not directly passed to the recognizer.
  /// Rather, we buffer the incoming data until [chunkLengthInSecs] is available, and then pass that chunk the recognizer.
  /// Use this parameter to increase/decrease the frequency with which the recognizer attempts to decode the stream.
  ///
  Future createRecognizer(double sampleRate, String tokensFilePath,
      String encoderFilePath, String decoderFilePath, String joinerFilePath,
      {double chunkLengthInSecs = 0.25, double hotwordsScore = 20.0}) async {
    await _isolateSetupComplete.future;
    final completer = Completer<bool>();
    late StreamSubscription listener;
    listener = _createdRecognizerPortStream.listen((success) {
      completer.complete(success);
      listener.cancel();
    });

    _createRecognizerPort.send([
      sampleRate,
      chunkLengthInSecs,
      tokensFilePath,
      encoderFilePath,
      decoderFilePath,
      joinerFilePath,
      hotwordsScore
    ]);

    var result = await completer.future;
    _hasRecognizer = true;
    return result;
  }

  Future createStream(List<String>? phrases) async {
    if (_createdStream != null) {
      throw Exception("A request to create a stream is already pending.");
    }
    _createdStream = Completer();
    _createStreamPort
        .send(phrases?.map((x) => x.split("").join(" ")).toList().join("\n"));
    var result = await _createdStream!.future;
    if (result) {
      _killed = false;
    } else {
      throw Exception("Failed to create stream. Is a recognizer available?");
    }
    _createdStream = null;
    return result;
  }

  Future destroyStream() {
    throw Exception("TODO");
  }

  Future destroyRecognizer() async {
    if (_hasRecognizer) {
      _killRecognizerPort.send(true);
      _killed = true;
    }
    _hasRecognizer = false;
  }

  void acceptWaveform(Uint8List data) async {
    if (_killed) {
      return;
    }
    _dataPort.send(data);
  }

  Future dispose() async {
    (await _runner)?.kill();
    await _setupListener.cancel();
    await _resultListener.cancel();
    await _createdStreamListener.cancel();
    _shutdownPort.send(true);
    _createdRecognizerPort.close();
    _createdStreamPort.close();
  }
}