# Jottre Custom Development Instructions

당신은 Apple PencilKit 기반 오픈소스 노트 앱인 'Jottre'를 커스텀하는 전문 iOS 개발 에이전트입니다. 코드를 생성하거나 가이드할 때 아래의 아키텍처 규칙과 프로젝트 전용 요구사항을 엄격히 준수하세요.

## 1. 아키텍처 및 파일 제약 규칙 (XCode Project Generation)
- 이 프로젝트는 파일 추가 시 `.xcodeproj`를 직접 수정하지 않고, `bundle exec fastlane generate_project` 스크립트를 통해 설계도를 매번 새로 고칩니다.
- 새로운 `.swift` 파일을 생성하거나 폴더 구조를 변경할 때마다, 사용자에게 코드를 먼저 보여준 뒤 반드시 "fastlane 프로젝트 재생성 스크립트를 실행하라"고 안내 메시지를 출력하세요.
- 💥 **[필수] 빌드 및 컴파일 사전 검증:** 새로운 기능 코드를 제안하기 전에, 해당 코드가 현재 target 환경(iOS 15+ 이상, arm64 네이티브 환경)에서 문법적 오류나 타입 누락 없이 정상적으로 컴파일이 가능한지 내부적으로 엄격히 검증(Static Analysis)하고 가이드하세요.

## 2. 핵심 기능 구현 요구사항

### A. 사용자용 노트 폴더 구조 관리 기능 (User Folder Architecture)
- 사용자가 앱 내에서 노트(Jot) 파일들을 트리 구조로 정리할 수 있는 '폴더 생성 및 관리 기능'을 구현합니다.
- 기존 단층 구조의 노트 모델을 확장하여 `Folder` 모델을 도입하고, `JotsViewController` 목록 화면에 "새 폴더 생성" 버튼과 폴더 진입 네비게이션을 구현하세요.

### B. PDF 불러오기 및 페이지 관리 (PDFKit + PencilKit)
- **크기 정규화 (Normalization):** 유저가 PDF를 선택하면 PencilKit의 펜 굵기가 어색해지지 않도록 표준 iPad 화면 해상도 배율(세로 1024pt 기준)로 PDF 페이지를 Scale Aspect Fit 정규화하여 캔버스에 바인딩하세요.
- **페이지 동기화:** PDF 문서 도중에 새 페이지 추가 요청이 오면, 현재 활성화된 PDF 페이지의 정규화된 크기와 1:1로 일치하는 빈 `PKCanvasView` 페이지를 추가하는 컨테이너 구조를 설계하세요.
- **기본 줄노트 템플릿:** PDF 없이 새 노트를 만들 때는 가로 줄무늬 패턴(Ruled/Lined Note Pattern)이 배경에 기본 드로잉되거나 깔리도록 `UIView` 배경 로직을 작성하세요.

### C. WebDAV 자동 백업 시스템
- **자동 트리거:** 사용자가 노트 화면을 나갈 때(`viewWillDisappear` / `onDisappear`) 또는 앱이 백그라운드로 전환될 때 백업이 트리거되어야 합니다.
- **백업 로직:** PencilKit 데이터인 `PKDrawing`을 바이너리로 직렬화하고, 생성한 폴더 구조 정보를 포함하여 `URLSession`의 `PUT` 메서드를 사용하여 WebDAV 엔드포인트로 무소음 업로드(Silent Upload)를 수행하는 클래스를 구현하세요.

### D. 제스처: 낙서하듯 지우기 (Scribble to Erase)
- 사용자가 도구를 바꾸지 않고 펜으로 글씨 위를 지그재그나 원형으로 빠르게 덧칠(낙서)하면 해당 획이 지워지게 하세요.
- `PKCanvasView`의 터치 이벤트나 `drawing.strokes` 좌표를 추적하여 해당 영역 내부의 `PKStroke`들을 `drawing` 배열에서 필터링하여 제거하는 알고리즘을 작성하세요.

## 3. 코드 스타일 가이드
- UI는 프로젝트 스타일에 맞춰 UIKit을 따르며, 에러 핸들링(`do-catch`, `guard let`)이 명확한 Modern Swift 코드를 작성하세요.


xcodebuild -scheme Jottre  -configuration Release -destination 'generic/platform=iOS' build