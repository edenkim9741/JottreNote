<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png" alt="Jottre Note icon" width="240">
</p>

# Jottre Note

Jottre Note는 오픈 소스 필기 앱 [Jottre](https://github.com/antonlorani/jottre)를 기반으로 만든 iPhone, iPad 및 Mac Catalyst용 필기 노트 앱입니다. UIKit과 PencilKit을 중심으로 PDF 위 필기, 다중 페이지 문서, 도형 보정 및 WebDAV 백업 기능을 확장했습니다.

> 이 저장소는 원본 Jottre의 파생 프로젝트입니다. 원본 앱의 App Store 배포본과 Jottre Note는 동일한 제품이 아닙니다.

![Jottre Note on iPad](jottre_ipad_app_preview.jpg)

## 주요 기능

### 필기 및 편집

- Apple Pencil과 손가락 입력을 지원하는 PencilKit 기반 캔버스
- 펜, 형광펜, 지우개 및 올가미 도구
- Pencil 전용 입력 상태에서 한 손가락 스크롤과 멀티 터치 확대·축소
- 올가미로 잉크를 이동한 뒤에도 유지되는 자연스러운 스크롤 동작
- 펜을 획 끝에서 잠시 유지하면 선, 원·타원, 사각형, 삼각형 및 화살표로 변환하는 Draw and Hold
- 문서 우측 상단 설정 메뉴에서 Draw and Hold 도형 변환 활성화 여부 설정
- 도형 변환과 잉크 편집을 포함한 실행 취소·다시 실행

### PDF 및 페이지

- 파일 앱과 외부 공유를 통한 단일 또는 여러 PDF 가져오기
- PDF 페이지 위 직접 필기와 빈 페이지 추가·삭제
- 원본 PDF 콘텐츠를 유지하는 Core Graphics 기반 페이지 렌더링
- 형광펜과 일반 잉크를 분리한 이중 캔버스 합성
  - 불투명한 배경을 가진 PDF에서도 형광펜을 표시
  - 형광펜 위에 일반 펜 잉크를 선명하게 렌더링
- 긴 문서에서도 메모리 사용량을 제한하는 페이지 단위 미리보기 및 내보내기
- 일부 PDF 제작 도구가 생성한 비정상 soft mask를 보정하는 호환성 처리

### 문서 관리

- 하위 호환성을 유지하는 버전 3 `.jot` 문서 형식
- 폴더, 이름 변경, 휴지통 및 파일 버전 충돌 처리
- 마지막으로 보던 페이지 복원
- PDF, PNG 및 JPEG 내보내기
- PDF 배경, 형광펜 및 일반 잉크의 레이어 순서를 내보내기와 미리보기에도 동일하게 적용

### WebDAV 백업

- WebDAV 서버 연결 설정 및 연결 테스트
- 현재 문서 또는 모든 `.jot` 문서의 수동 백업
- 폴더 구조를 유지한 `.jot` 원본과 렌더링된 PDF 동시 업로드
- 분 단위 자동 백업 주기 설정 (`0`은 비활성화)
- 앱 사용 중 주기 백업과 `BGTaskScheduler`를 이용한 백그라운드 처리
- 백업 전 열린 편집기의 저장을 완료하고 파일 변경 작업을 직렬화해 충돌 방지
- 네트워크 오류 발생 시 UI를 막지 않고 다음 작업을 다시 예약

## 기술 구성

| 영역 | 구현 |
| --- | --- |
| UI 및 입력 | UIKit, PencilKit, PDFKit |
| PDF 렌더링 | Core Graphics, `UIGraphicsPDFRenderer` |
| 구조 | MVVM-C, Coordinator, `AsyncStream` 기반 상태 전달 |
| 동시성 | Swift 6 strict concurrency, actor 기반 저장 및 백업 직렬화 |
| 파일 처리 | `.jot` Codable 모델, `NSFileCoordinator`, 파일 버전 충돌 처리 |
| 백그라운드 작업 | `BGTaskScheduler`, 활성 세션 주기 스케줄러 |
| 대상 플랫폼 | iOS/iPadOS 16 이상, Mac Catalyst |

## 프로젝트 구조

```text
Sources/
├── EditJotPage/       # 캔버스, 도구, 터치 라우팅, 도형 변환
├── Jot/               # .jot 문서 모델과 직렬화
├── PDF/               # PDF 로드, 호환성 보정 및 페이지 렌더링
├── FileService/       # 로컬 파일 및 외부 PDF 가져오기
├── JotFilePreview/    # 문서 미리보기 생성과 캐시
├── JotsPage/          # 문서·폴더·휴지통 및 공유 UI
├── SettingsPage/      # 앱 및 WebDAV 설정
└── WebDAV/            # 업로드, 작업 잠금 및 자동 백업 스케줄러
CoreTests/             # 문서, 렌더링, 제스처 및 스케줄러 단위 테스트
```

## 개발 환경

- Xcode: `.xcode-version`에 지정된 버전
- Ruby: `.ruby-version`에 지정된 버전
- Swift 6, complete strict concurrency
- XcodeGen과 Fastlane

### 설치

[rbenv](https://github.com/rbenv/rbenv)로 저장소에 지정된 Ruby 버전을 설치합니다.

```sh
curl -fsSL https://github.com/rbenv/rbenv-installer/raw/HEAD/bin/rbenv-installer | bash
rbenv install $(cat .ruby-version)
rbenv local $(cat .ruby-version)
gem install bundler
bundle install
```

필요한 Xcode 버전은 [xcodes](https://github.com/XcodesOrg/xcodes)로 설치할 수 있습니다.

```sh
brew install xcodesorg/made/xcodes aria2
xcodes install $(cat .xcode-version) --experimental-unxip
xcodes select $(cat .xcode-version)
```

Xcode 프로젝트를 생성합니다.

```sh
bundle exec fastlane ios generate_project
open Jottre.xcodeproj
```

### 빌드 및 검증

```sh
# iOS/iPadOS Debug 빌드
bundle exec fastlane ios build_debug

# Mac Catalyst Debug 빌드
bundle exec fastlane mac build_debug

# 단위 테스트
bundle exec fastlane ios test
```

`project.yml`이 프로젝트 구성의 기준이므로, 타깃이나 빌드 설정을 변경한 뒤에는 Xcode 프로젝트를 다시 생성해야 합니다.

## 기여

기여하기 전에 다음 문서를 확인해 주세요.

- [기여 가이드](CONTRIBUTING.md)
- [행동 강령](CODE_OF_CONDUCT.md)
- [보안 정책](SECURITY_POLICY.md)

## 원본 프로젝트와 라이선스

Jottre Note는 Anton Lorani의 [Jottre](https://github.com/antonlorani/jottre)를 기반으로 하며, 원본 프로젝트의 저작권 고지와 라이선스를 유지합니다.

이 프로젝트는 [GNU General Public License v3.0](LICENSE)에 따라 배포됩니다. GPLv3가 허용하는 범위에서 소프트웨어를 사용, 수정 및 재배포할 수 있으며, 동일한 라이선스 의무가 적용됩니다.
