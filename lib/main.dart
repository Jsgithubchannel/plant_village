import 'dart:io'; // 파일 입출력
import 'package:flutter/material.dart'; // 플러터 기본 위젯
import 'package:flutter/services.dart'; // 에셋 로딩 (rootBundle)
import 'package:image_picker/image_picker.dart'; // 이미지 선택
import 'package:tflite_flutter/tflite_flutter.dart'; // TFLite 연동
import 'package:image/image.dart' as img; // 이미지 처리 (리사이징, 픽셀 접근)

// 앱 진입점
void main() {
  // Flutter 엔진과 위젯 트리가 바인딩되었는지 확인 (플러그인 초기화 전에 필요)
  WidgetsFlutterBinding.ensureInitialized();
  // 앱 실행
  runApp(MyApp());
}

// 앱의 루트 위젯 (MaterialApp 설정)
class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Plant Classifier', // 앱의 제목 (예: 최근 앱 목록)
      theme: ThemeData(
        // 앱 테마 설정
        primarySwatch: Colors.green, // 기본 색상 견본
        visualDensity: VisualDensity.adaptivePlatformDensity, // 플랫폼별 시각적 밀도 조정
      ),
      home: PlantClassifierPage(), // 앱이 시작될 때 보여줄 기본 페이지
      debugShowCheckedModeBanner: false, // 디버그 배너 숨기기
    );
  }
}

// --- 식물 분류기 페이지 위젯 ---
class PlantClassifierPage extends StatefulWidget {
  @override
  _PlantClassifierPageState createState() => _PlantClassifierPageState();
}

// --- 식물 분류기 페이지의 상태 관리 클래스 ---
class _PlantClassifierPageState extends State<PlantClassifierPage> {
  File? _image; // 선택된 이미지 파일
  List<String>? _labels; // 모델 레이블 리스트
  Interpreter? _interpreter; // TFLite 인터프리터
  String _result = "이미지를 선택해주세요."; // 결과 메시지
  bool _isLoading = false; // 로딩 상태 플래그
  final double confidenceThreshold = 0.7; // 신뢰도 임계값 (조정 필요)

  // 위젯 초기화 시 모델 및 레이블 로드
  @override
  void initState() {
    super.initState();
    // 비동기 작업인 모델/레이블 로드를 initState에서 호출
    // 위젯이 완전히 빌드된 후 실행하려면 WidgetsBinding.instance.addPostFrameCallback 사용 가능
    _loadModel();
    _loadLabels();
  }

  // 위젯이 제거될 때 인터프리터 리소스 해제
  @override
  void dispose() {
    _interpreter?.close();
    super.dispose();
  }

  // TFLite 모델 로드 함수
  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('plant_model.tflite');
      print('모델 로드 성공');
      // 모델 로드 후 상태 업데이트가 필요하다면 setState 사용 (여기선 필요 X)
    } catch (e) {
      print('모델 로드 실패: $e');
      if (mounted) {
        // 위젯이 여전히 화면에 있는지 확인 후 상태 업데이트
        setState(() {
          _result = "모델 로딩 실패: $e";
        });
      }
    }
  }

  // 레이블 파일 로드 함수
  Future<void> _loadLabels() async {
    try {
      final labelData = await rootBundle.loadString('assets/labels.txt');
      // 각 줄을 분리하고, 공백 제거 후 비어있지 않은 라인만 리스트로 만듦
      _labels =
          labelData
              .split('\n')
              .map((label) => label.trim())
              .where((label) => label.isNotEmpty)
              .toList();
      print('레이블 로드 성공: ${_labels?.length ?? 0}개');
      if (_labels == null || _labels!.isEmpty) {
        print('경고: 레이블 파일이 비어있거나 로드에 실패했습니다.');
        if (mounted) {
          setState(() {
            _result = "레이블 파일 오류";
          });
        }
      }
    } catch (e) {
      print('레이블 로드 실패: $e');
      if (mounted) {
        setState(() {
          _result = "레이블 로딩 실패: $e";
        });
      }
    }
  }

  // 이미지 선택 함수 (갤러리 또는 카메라)
  Future<void> _pickImage(ImageSource source) async {
    // 로딩 중일 때는 버튼 비활성화되므로 추가 선택 방지
    if (_isLoading) return;

    final picker = ImagePicker();
    try {
      // 이미지 품질을 약간 낮춰 메모리 부족 문제 완화 시도 (0-100)
      final pickedFile = await picker.pickImage(
        source: source,
        imageQuality: 60,
      );

      if (pickedFile != null) {
        if (mounted) {
          // 이미지 선택 시 로딩 상태 활성화 및 메시지 변경
          setState(() {
            _image = File(pickedFile.path);
            _isLoading = true;
            _result = "분석 중...";
          });
        }
        // 이미지 선택 후 바로 추론 실행
        await _runInference();
      } else {
        print('이미지 선택이 취소되었습니다.');
      }
    } catch (e) {
      print('이미지 선택 오류: $e');
      if (mounted) {
        setState(() {
          _result = '이미지 선택 오류: $e';
          _isLoading = false; // 오류 발생 시 로딩 상태 해제
        });
      }
    }
  }

  // 이미지 전처리 및 TFLite 추론 실행 함수
  Future<void> _runInference() async {
    // 필수 요소들이 준비되었는지 확인
    if (!mounted ||
        _image == null ||
        _interpreter == null ||
        _labels == null ||
        _labels!.isEmpty) {
      if (mounted) {
        setState(() {
          _result = "오류: 분석 준비 안됨 (이미지, 모델, 또는 레이블 없음)";
          _isLoading = false;
        });
      }
      return;
    }

    img.Image? originalImage;
    try {
      // 1. 이미지 파일 읽고 디코딩
      final imageBytes = await _image!.readAsBytes();
      originalImage = img.decodeImage(imageBytes);

      if (originalImage == null) throw Exception('이미지 디코딩 실패');

      // 2. 이미지 리사이징 (모델 입력 크기에 맞게)
      img.Image resizedImage = img.copyResize(
        originalImage,
        width: 160,
        height: 160,
      );

      // 3. 이미지 정규화 (학습 시 사용한 방식과 동일하게 [-1, 1] 범위로)
      // 입력 형태: [1, 160, 160, 3] (배치, 높이, 너비, 채널)
      var input = List.generate(
        1,
        (i) => List.generate(
          160,
          (j) => List.generate(160, (k) => List.generate(3, (l) => 0.0)),
        ),
      );
      var buffer = resizedImage.getBytes(
        order: img.ChannelOrder.rgb,
      ); // RGB 순서로 바이트 가져오기
      int pixelIndex = 0;
      for (int y = 0; y < 160; y++) {
        for (int x = 0; x < 160; x++) {
          input[0][y][x][0] = (buffer[pixelIndex++] / 127.5) - 1.0; // R
          input[0][y][x][1] = (buffer[pixelIndex++] / 127.5) - 1.0; // G
          input[0][y][x][2] = (buffer[pixelIndex++] / 127.5) - 1.0; // B
        }
      }

      // 4. 모델 추론 실행
      // 출력 형태: [1, label개수] (예: [1, 38])
      var output = List.filled(
        1 * _labels!.length,
        0.0,
      ).reshape([1, _labels!.length]);
      _interpreter!.run(input, output);

      // 5. 결과 처리 및 "식물 아님" 판단 로직
      double maxProb = 0.0;
      int predictedIndex = -1;

      // 가장 높은 확률값과 인덱스 찾기
      for (int i = 0; i < output[0].length; i++) {
        if (output[0][i] > maxProb) {
          maxProb = output[0][i];
          predictedIndex = i;
        }
      }

      String finalResult;
      // 신뢰도 임계값 이상이고 유효한 인덱스인 경우
      if (predictedIndex != -1 && maxProb >= confidenceThreshold) {
        if (predictedIndex < _labels!.length) {
          // 레이블 범위 확인
          String predictedLabel = _labels![predictedIndex];
          List<String> parts = predictedLabel.split('___'); // 레이블 파싱
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
      }
      // 신뢰도 임계값 미만인 경우
      else if (predictedIndex != -1) {
        finalResult =
            "식물 이미지가 아니거나,\n모델이 확신할 수 없는 이미지입니다.\n(최고 신뢰도: ${(maxProb * 100).toStringAsFixed(1)}%)";
      }
      // 예측 인덱스를 찾지 못한 경우 (이론상 발생하기 어려움)
      else {
        finalResult = "분석 실패: 예측 결과 없음";
      }

      // UI 업데이트 (위젯이 화면에 있을 때만)
      if (mounted) {
        setState(() {
          _result = finalResult;
          _isLoading = false;
        });
      }
    } catch (e) {
      print("추론 또는 이미지 처리 중 오류: $e");
      if (mounted) {
        setState(() {
          _result = "오류 발생: ${e.toString()}";
          _isLoading = false;
        });
      }
    }
  }

  // 위젯 UI 구성
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('🌿 식물 상태 진단'),
        backgroundColor: Colors.green[700], // AppBar 색상 변경
      ),
      body: SingleChildScrollView(
        // 화면 넘칠 경우 스크롤 가능하도록
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0), // 전체적인 여백 추가
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                // 이미지 표시 영역
                Container(
                  width: double.infinity, // 너비 최대로
                  height:
                      MediaQuery.of(context).size.width * 0.7, // 화면 너비의 70% 높이
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade400),
                    borderRadius: BorderRadius.circular(12.0),
                    color: Colors.grey[100], // 배경색 약간 추가
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
                            // 이미지가 컨테이너 경계를 넘지 않도록
                            borderRadius: BorderRadius.circular(12.0),
                            child: Image.file(
                              _image!,
                              fit: BoxFit.contain, // 이미지가 잘리지 않도록 contain 사용
                            ),
                          ),
                ),
                SizedBox(height: 25), // 간격 추가
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
                            : Colors.green[50], // 로딩 중 배경색 변경
                    border: Border.all(
                      color:
                          _isLoading
                              ? Colors.orange.shade200
                              : Colors.green.shade200,
                    ),
                    borderRadius: BorderRadius.circular(8.0),
                  ),
                  child:
                      _isLoading
                          ? Row(
                            // 로딩 인디케이터와 텍스트 표시
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
                            // 결과 텍스트 표시
                            _result,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                ),
                SizedBox(height: 30), // 간격 추가
                // 버튼 영역
                Row(
                  mainAxisAlignment:
                      MainAxisAlignment.spaceEvenly, // 버튼 간격 균등하게
                  children: [
                    ElevatedButton.icon(
                      icon: Icon(Icons.photo_library_outlined),
                      label: Text('갤러리'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.teal, // 버튼 색상
                        padding: EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        textStyle: TextStyle(fontSize: 15),
                      ),
                      // 로딩 중일 때는 버튼 비활성화 (null 전달)
                      onPressed:
                          _isLoading
                              ? null
                              : () => _pickImage(ImageSource.gallery),
                    ),
                    ElevatedButton.icon(
                      icon: Icon(Icons.camera_alt_outlined),
                      label: Text('카메라'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey, // 버튼 색상
                        padding: EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        textStyle: TextStyle(fontSize: 15),
                      ),
                      // 로딩 중일 때는 버튼 비활성화
                      onPressed:
                          _isLoading
                              ? null
                              : () => _pickImage(ImageSource.camera),
                    ),
                  ],
                ),
                SizedBox(height: 20), // 하단 여백
              ],
            ),
          ),
        ),
      ),
    );
  }
}
