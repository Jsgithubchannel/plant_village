import 'dart:io'; // 파일 입출력
import 'package:flutter/material.dart'; // 플러터 기본 위젯
import 'package:flutter/services.dart'; // 에셋 로딩 (rootBundle)

// Firebase 및 ML 관련 패키지
import 'package:firebase_core/firebase_core.dart'; // Firebase 코어
import 'package:firebase_ml_model_downloader/firebase_ml_model_downloader.dart'; // Firebase 모델 다운로더
import 'firebase_options.dart'; // FlutterFire CLI가 생성한 파일 (중요!)

// 이미지 및 TFLite 관련 패키지
import 'package:image_picker/image_picker.dart'; // 이미지 선택
import 'package:tflite_flutter/tflite_flutter.dart'; // TFLite 연동 (인터프리터 사용 위해 여전히 필요)
import 'package:image/image.dart' as img; // 이미지 처리 (리사이징, 픽셀 접근)

// --- 앱 진입점 ---
void main() async {
  // main 함수를 async로 변경
  // Flutter 엔진과 위젯 트리가 바인딩되었는지 확인 (플러그인 초기화 전에 필요)
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase 초기화 - 앱 시작 시 필수!
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    print("Firebase 초기화 실패: $e");
    // 초기화 실패 시 사용자에게 알림 또는 다른 처리 필요
  }

  // 앱 실행
  runApp(MyApp());
}

// --- 앱의 루트 위젯 (MaterialApp 설정) ---
class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Plant Classifier (Firebase)', // 앱 제목 변경
      theme: ThemeData(
        primarySwatch: Colors.green,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: PlantClassifierPage(), // 앱 시작 페이지
      debugShowCheckedModeBanner: false,
    );
  }
}

// --- 식물 분류기 페이지 위젯 (StatefulWidget) ---
class PlantClassifierPage extends StatefulWidget {
  @override
  _PlantClassifierPageState createState() => _PlantClassifierPageState();
}

// --- 식물 분류기 페이지의 상태 관리 클래스 ---
class _PlantClassifierPageState extends State<PlantClassifierPage> {
  File? _image; // 선택된 이미지 파일
  List<String>? _labels; // 모델 레이블 리스트 (에셋에서 로드)
  Interpreter? _interpreter; // TFLite 인터프리터 (다운로드된 모델로 생성)
  String _result = "모델 및 레이블 로딩 중..."; // 초기 상태 메시지 변경
  bool _isLoading = true; // 초기 로딩 상태 true
  bool _isModelReady = false; // 모델 준비 완료 여부 플래그
  final double confidenceThreshold = 0.7; // 신뢰도 임계값

  // Firebase 콘솔에 업로드한 모델 이름과 정확히 일치해야 함
  static const String _firebaseModelName = "plant-village-classifier-v1";

  // 위젯 초기화 시 모델 및 레이블 로드 시도
  @override
  void initState() {
    super.initState();
    _initializeModelAndLabels(); // 모델과 레이블 초기화 함수 호출
  }

  // 위젯이 제거될 때 인터프리터 리소스 해제
  @override
  void dispose() {
    _interpreter?.close();
    print("Interpreter 자원 해제됨");
    super.dispose();
  }

  // 모델과 레이블을 비동기적으로 로드하는 초기화 함수
  Future<void> _initializeModelAndLabels() async {
    // 두 작업을 동시에 시작
    final modelFuture = _loadModelFromFirebase();
    final labelsFuture = _loadLabelsFromAssets();

    // 두 작업이 모두 완료될 때까지 기다림
    await Future.wait([modelFuture, labelsFuture]);

    // 모든 로딩 완료 후 상태 업데이트
    if (mounted) {
      setState(() {
        _isLoading = false; // 로딩 완료
        if (_isModelReady && _labels != null && _labels!.isNotEmpty) {
          _result = "이미지를 선택해주세요."; // 성공 메시지
        } else {
          // 실패 메시지는 각 로드 함수 내부에서 설정됨
          _result = _result.contains("실패") ? _result : "초기화 실패";
        }
      });
    }
  }

  // Firebase Model Downloader를 사용하여 모델 로드 및 인터프리터 생성
  Future<void> _loadModelFromFirebase() async {
    try {
      final FirebaseModelDownloader modelDownloader =
          FirebaseModelDownloader.instance;

      // 최신 모델 가져오기 시도 (네트워크 연결 필요할 수 있음)
      final FirebaseCustomModel firebaseModel = await modelDownloader.getModel(
        _firebaseModelName,
        FirebaseModelDownloadType.latestModel, // 항상 최신 버전 시도
        FirebaseModelDownloadConditions(
          iosAllowsCellularAccess: true,
          // androidAllowsCellularAccess: true,
        ),
      );

      // 다운로드된 모델 파일 가져오기
      final File modelFile = firebaseModel.file;

      // 다운로드된 파일로부터 TFLite Interpreter 로드 (tflite_flutter 사용)
      _interpreter = Interpreter.fromFile(modelFile);
      print('다운로드된 모델로부터 Interpreter 로드 성공');
      _isModelReady = true; // 모델 준비 완료
    } catch (e) {
      print('Firebase 모델 다운로드 또는 Interpreter 로드 실패: $e');
      _isModelReady = false;
      // 에러 발생 시 사용자에게 보여줄 메시지 설정 (setState는 _initializeModelAndLabels 에서 처리)
      _result = "모델 준비 실패:\n${e.toString()}";
    }
  }

  // 에셋에서 레이블 파일 로드 함수
  Future<void> _loadLabelsFromAssets() async {
    try {
      final labelData = await rootBundle.loadString('assets/labels.txt');
      _labels =
          labelData
              .split('\n')
              .map((label) => label.trim())
              .where((label) => label.isNotEmpty)
              .toList();
      if (_labels == null || _labels!.isEmpty) {
        throw Exception('레이블 파일이 비어있거나 내용을 읽을 수 없습니다.');
      }
    } catch (e) {
      print('레이블 로드 실패: $e');
      _labels = null; // 실패 시 null 처리
      _result = "레이블 파일 로드 실패:\n${e.toString()}";
    }
  }

  // 이미지 선택 함수 (갤러리 또는 카메라) - 변경 없음
  Future<void> _pickImage(ImageSource source) async {
    // 모델이 준비되지 않았거나 이미 로딩 중이면 실행하지 않음
    if (!_isModelReady || _isLoading) return;

    final picker = ImagePicker();
    try {
      final pickedFile = await picker.pickImage(
        source: source,
        imageQuality: 60,
      );

      if (pickedFile != null) {
        if (mounted) {
          setState(() {
            _image = File(pickedFile.path);
            _isLoading = true; // 추론 시작 전 로딩 상태 활성화
            _result = "분석 중...";
          });
        }
        await _runInference(); // 이미지 선택 후 바로 추론 실행
      } else {
        print('이미지 선택이 취소되었습니다.');
      }
    } catch (e) {
      print('이미지 선택 오류: $e');
      if (mounted) {
        setState(() {
          _result = '이미지 선택 오류: $e';
          _isLoading = false;
        });
      }
    }
  }

  // 이미지 전처리 및 TFLite 추론 실행 함수 - **로직 변경 없음**
  Future<void> _runInference() async {
    // 필수 요소 확인 (모델 준비 여부 포함)
    if (!mounted ||
        _image == null ||
        !_isModelReady ||
        _interpreter == null ||
        _labels == null ||
        _labels!.isEmpty) {
      if (mounted) {
        setState(() {
          _result = "오류: 분석 준비 안됨 (모델 또는 레이블 로드 실패)";
          _isLoading = false;
        });
      }
      return;
    }

    img.Image? originalImage;
    try {
      // 1. 이미지 로드 및 디코딩
      final imageBytes = await _image!.readAsBytes();
      originalImage = img.decodeImage(imageBytes);
      if (originalImage == null) throw Exception('이미지 디코딩 실패');

      // 2. 이미지 리사이징
      img.Image resizedImage = img.copyResize(
        originalImage,
        width: 160,
        height: 160,
      );

      // 3. 이미지 정규화 ([-1, 1] 범위)
      var input = List.generate(
        1,
        (i) => List.generate(
          160,
          (j) => List.generate(160, (k) => List.generate(3, (l) => 0.0)),
        ),
      );
      var buffer = resizedImage.getBytes(order: img.ChannelOrder.rgb);
      int pixelIndex = 0;
      for (int y = 0; y < 160; y++) {
        for (int x = 0; x < 160; x++) {
          input[0][y][x][0] = (buffer[pixelIndex++] / 127.5) - 1.0; // R
          input[0][y][x][1] = (buffer[pixelIndex++] / 127.5) - 1.0; // G
          input[0][y][x][2] = (buffer[pixelIndex++] / 127.5) - 1.0; // B
        }
      }

      // 4. 모델 추론 실행 (로드된 _interpreter 사용)
      var output = List.filled(
        1 * _labels!.length,
        0.0,
      ).reshape([1, _labels!.length]);
      _interpreter!.run(input, output);

      // 상위 5개 예측 결과 출력 로직 추가/수정
      // 모델 출력 확률값 리스트 가져오기 (output 형태가 [1, N]이라고 가정)
      final List<double> probabilities = output[0];

      // (인덱스, 확률) 쌍 리스트 생성
      List<Map<String, dynamic>> indexedProbabilities = [];
      for (int i = 0; i < probabilities.length; i++) {
        indexedProbabilities.add({'index': i, 'prob': probabilities[i]});
      }

      // 확률 기준으로 내림차순 정렬
      indexedProbabilities.sort((a, b) => b['prob'].compareTo(a['prob']));

      // 상위 5개 (또는 클래스 개수보다 작으면 그 개수만큼) 추출
      int topN = 5;
      List<Map<String, dynamic>> topPredictions =
          indexedProbabilities.take(topN).toList();

      // 터미널에 상위 5개 결과 출력
      print("--- Top 5 Predictions ---");
      for (int i = 0; i < topPredictions.length; i++) {
        var prediction = topPredictions[i];
        int index = prediction['index'];
        double prob = prediction['prob'];

        // 레이블 존재 및 인덱스 유효성 확인
        if (_labels != null && index >= 0 && index < _labels!.length) {
          String predictedLabel = _labels![index];
          List<String> parts = predictedLabel.split('___');
          String species =
              parts.length > 0 ? parts[0].replaceAll('_', ' ') : '알 수 없음';
          String status =
              parts.length > 1 ? parts[1].replaceAll('_', ' ') : '알 수 없음';

          // 출력 형식: 순위. 종류 (상태): 신뢰도%
          print(
            "${i + 1}. ${species} (${status}): ${(prob * 100).toStringAsFixed(2)}%",
          );
        } else {
          print("${i + 1}. Error: Invalid index $index for probability $prob");
        }
      }
      print("-------------------------");

      // 5. 결과 처리 및 "식물 아님" 판단 로직 (신뢰도 기반)
      double maxProb = 0.0;
      int predictedIndex = -1;
      for (int i = 0; i < output[0].length; i++) {
        if (output[0][i] > maxProb) {
          maxProb = output[0][i];
          predictedIndex = i;
        }
      }

      String finalResult;
      if (predictedIndex != -1 && maxProb >= confidenceThreshold) {
        if (predictedIndex < _labels!.length) {
          String predictedLabel = _labels![predictedIndex];
          List<String> parts = predictedLabel.split('___');
          String species =
              parts.length > 0 ? parts[0].replaceAll('_', ' ') : '알 수 없음';
          String status =
              parts.length > 1 ? parts[1].replaceAll('_', ' ') : '알 수 없음';
          finalResult =
              "종류: $species\n상태: $status\n(신뢰도: ${(maxProb * 100).toStringAsFixed(1)}%)";
        } else {
          finalResult = "오류: 예측 인덱스가 레이블 범위를 벗어남";
          print(
            "오류: predictedIndex $predictedIndex >= label length ${_labels!.length}",
          );
        }
      } else if (predictedIndex != -1) {
        finalResult =
            "식물 이미지가 아니거나,\n모델이 확신할 수 없는 이미지입니다.\n(최고 신뢰도: ${(maxProb * 100).toStringAsFixed(1)}%)";
      } else {
        finalResult = "분석 실패: 예측 결과 없음";
      }

      // UI 업데이트
      if (mounted) {
        setState(() {
          _result = finalResult;
          _isLoading = false; // 추론 완료 후 로딩 상태 해제
        });
      }
    } catch (e) {
      print("추론 또는 이미지 처리 중 오류: $e");
      if (mounted) {
        setState(() {
          _result = "오류 발생: ${e.toString()}";
          _isLoading = false; // 오류 발생 시 로딩 상태 해제
        });
      }
    }
  }

  // --- 위젯 UI 구성 ---
  @override
  Widget build(BuildContext context) {
    // 모델/레이블 로딩 중 또는 추론 중일 때 버튼 비활성화 결정
    bool buttonsEnabled = _isModelReady && !_isLoading;

    return Scaffold(
      appBar: AppBar(
        title: Text('🌿 식물 상태 진단'),
        backgroundColor: const Color.fromARGB(
          255,
          228,
          255,
          230,
        ), // 테마 색상 변경 예시
      ),
      body: SingleChildScrollView(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                // 이미지 표시 영역
                Container(
                  width: double.infinity,
                  height: MediaQuery.of(context).size.width * 0.7,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade400),
                    borderRadius: BorderRadius.circular(12.0),
                    color: Colors.grey[100],
                  ),
                  child:
                      _image == null
                          ? Center(
                            child: Text(
                              '이미지를 선택하면 여기에 표시됩니다.',
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                          )
                          : ClipRRect(
                            borderRadius: BorderRadius.circular(12.0),
                            child: Image.file(_image!, fit: BoxFit.contain),
                          ),
                ),
                SizedBox(height: 25),

                // 결과 표시 영역
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(
                    vertical: 15.0,
                    horizontal: 10.0,
                  ),
                  decoration: BoxDecoration(
                    color:
                        _isLoading
                            ? Colors.orange[50]
                            : (_result.contains("실패") || _result.contains("오류")
                                ? Colors.red[50]
                                : Colors.green[50]),
                    border: Border.all(
                      color:
                          _isLoading
                              ? Colors.orange.shade200
                              : (_result.contains("실패") ||
                                      _result.contains("오류")
                                  ? Colors.red.shade200
                                  : Colors.green.shade200),
                    ),
                    borderRadius: BorderRadius.circular(8.0),
                  ),
                  child:
                      _isLoading &&
                              !_isModelReady // 초기 로딩 구분
                          ? Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                ),
                              ),
                              SizedBox(width: 15),
                              Text(
                                "모델 준비 중...",
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          )
                          : (_isLoading // 추론 중 로딩
                              ? Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 3,
                                    ),
                                  ),
                                  SizedBox(width: 15),
                                  Text(
                                    _result,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              )
                              : Text(
                                // 최종 결과 또는 에러 메시지
                                _result,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                ),
                              )),
                ),
                SizedBox(height: 30),

                // 버튼 영역
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      icon: Icon(Icons.photo_library_outlined),
                      label: Text('갤러리'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color.fromARGB(
                          255,
                          216,
                          241,
                          215,
                        ),
                        padding: EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        textStyle: TextStyle(fontSize: 15),
                        // 버튼 활성화/비활성화 상태에 따른 시각적 피드백
                        disabledBackgroundColor: Colors.grey.shade300,
                      ),
                      // 모델 준비 완료되고 로딩 중 아닐 때만 활성화
                      onPressed:
                          buttonsEnabled
                              ? () => _pickImage(ImageSource.gallery)
                              : null,
                    ),
                  ],
                ),
                SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
