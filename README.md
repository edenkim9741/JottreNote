<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png" alt="Jottre Note icon" width="240">
</p>

# Jottre Note

Jottre Note는 Zotero 라이브러리의 PDF를 iPad에서 읽고 Apple Pencil로 필기하기 위한 앱입니다. Zotero Web API로 컬렉션과 문서 정보를 동기화하고, Zotero WebDAV에서 PDF를 필요할 때 내려받습니다. PDF의 원래 페이지와 텍스트를 보존하면서 필기를 편집하고 다시 Zotero에 저장할 수 있습니다.

이 저장소는 [Jottre](https://github.com/antonlorani/jottre)를 기반으로 한 파생 프로젝트입니다. 원본 Jottre와 Jottre Note는 별개의 제품입니다.

![Jottre Note on iPad](jottre_ipad_app_preview.jpg)

## 주요 기능

### Zotero 라이브러리

- 앱을 열면 로컬 캐시의 컬렉션 트리를 먼저 표시하고, 백그라운드에서 Zotero 변경 사항을 동기화합니다.
- 컬렉션 계층, 미분류 항목, 휴지통을 탐색하고 제목·추가 날짜·최근 수정일 순으로 문서를 정렬할 수 있습니다.
- 하나의 Zotero 항목에 연결된 여러 PDF 첨부파일을 각각 열 수 있습니다.
- 문서 제목·작성자·날짜를 편집하고, 항목을 컬렉션으로 이동하거나 휴지통으로 보내고 복원할 수 있습니다.
- 여러 문서를 선택해 한 번에 컬렉션으로 이동하거나 삭제할 수 있습니다. 휴지통에서는 복원 또는 영구 삭제를 선택합니다.
- 새 줄노트를 세로 또는 가로 방향으로 만들 수 있습니다. 제목, 기본 작성자, 선택한 컬렉션을 Zotero 항목에 반영합니다.

### PDF 필기 및 페이지 관리

- PDF 페이지 위에 PencilKit으로 필기하고 펜, 형광펜, 지우개, 올가미 및 자 도구를 사용할 수 있습니다.
- 새 줄노트 페이지를 삽입하고, 페이지를 휴지통으로 이동하거나 원래 위치로 복원할 수 있습니다.
- 페이지 추가 시 문서의 페이지 크기를 사용합니다. 원본 PDF 페이지는 PDFKit으로 유지하고 잉크는 벡터 PDF Ink 주석으로 내보냅니다.
- 문서를 저장하면 로컬 캐시를 먼저 갱신합니다. 수정된 페이지는 디바운스 저장으로 처리하며, 화면을 닫을 때 대기 중인 변경을 저장합니다.
- PDF 내보내기에는 표준 PDF와 벡터 잉크 주석을 포함합니다. 앱에서 다시 편집하는 데 필요한 Jot 데이터는 PDF EOF 뒤의 하이브리드 페이로드로 보존합니다.

### 동기화와 오프라인 작업

- Zotero 컬렉션·아이템 메타데이터는 버전 기반 증분 동기화와 전체 컬렉션 대조를 사용해 로컬 JSON 캐시에 저장합니다.
- 문서를 탭할 때만 WebDAV의 `zotero/{첨부파일Key}.zip`을 내려받아 PDF를 엽니다.
- 저장한 문서는 해당 첨부파일 키의 ZIP과 Zotero WebDAV `.prop` 파일로 업로드하고 Zotero API의 첨부파일 메타데이터를 갱신합니다.
- WebDAV ZIP 안에는 외부 PDF 뷰어에서 열 수 있는 PDF와 앱 재편집용 `.jot` 데이터가 들어갑니다. PDF에는 벡터 잉크 주석이 포함됩니다.
- 네트워크가 없을 때 만든 노트는 로컬 초안으로 열 수 있으며, 연결이 복구되면 Zotero 항목과 첨부파일을 생성해 동기화합니다.
- 서버와 로컬 필기본이 충돌하면 로컬 충돌 사본을 보존하고, 동기화 대상에서 격리합니다. 충돌 해결 화면에서 로컬본 유지, 서버본 유지 또는 둘 다 보관을 선택할 수 있습니다.
- 설정에서 내려받은 문서와 용량을 확인하고, 동기화가 끝난 로컬 파일을 선택하거나 전체 오프로드할 수 있습니다. 수정 대기 중인 파일은 오프로드 대상에서 보호됩니다.

## Zotero 설정

앱의 설정 화면에서 다음 정보를 입력합니다.

1. Zotero User ID와 API Key를 입력합니다. API Key로 User ID를 조회할 수도 있습니다.
2. Zotero WebDAV 서버 URL, 사용자 이름, 비밀번호를 입력합니다.
3. 필요하면 새 노트에 사용할 기본 작성자를 설정합니다.

API Key와 WebDAV 비밀번호는 Keychain에 보관합니다. 컬렉션·문서 메타데이터 캐시는 앱의 Application Support 디렉터리에 사용자별 JSON 파일로 저장됩니다. PDF 파일은 앱 캐시 디렉터리에 저장하고, 편집 데이터는 Application Support의 로컬 저장소에 보관합니다.

## 데이터 흐름

```text
Zotero Web API ── 컬렉션/문서 메타데이터 ──> 로컬 JSON 캐시 ──> 라이브러리 화면
                                                     │
문서 선택 ──> Zotero WebDAV ZIP ──> PDF + .jot 데이터 ─┘
                                      │
                                  필기/저장
                                      │
하이브리드 PDF ──> 벡터 PDF + .jot 데이터 ──> PDF/.jot ZIP + .prop ──> Zotero WebDAV
```

## 기술 구성

| 영역 | 구현 |
| --- | --- |
| 라이브러리 UI | SwiftUI `NavigationSplitView` |
| PDF 편집 | UIKit, PDFKit, PencilKit |
| Zotero 연결 | Zotero Web API, WebDAV, ZIP 패키징 |
| 로컬 데이터 | 사용자별 원자적 JSON 메타데이터 캐시, 앱 파일 저장소 |
| 잉크 저장 | PDFKit Ink 주석, `%%EOF` 뒤 Jottre 페이로드 |
| 대상 플랫폼 | iOS/iPadOS 18 이상 |
| 프로젝트 생성 | XcodeGen |

화면 문자열은 Xcode String Catalog로 관리하며 한국어와 영어를 포함한 다국어 리소스를 사용합니다.

## 프로젝트 구조

```text
Sources/
├── EditJotPage/       # PencilKit 편집기, 저장, 페이지 관리
├── Jot/               # 필기 문서 모델 및 직렬화
├── PDF/               # PDF 주석 변환, 하이브리드 PDF, 줄노트 생성
├── SettingsPage/      # Zotero 계정, WebDAV 및 로컬 캐시 설정
└── WebDAV/            # Zotero API, 캐시, WebDAV 및 동기화 엔진
CoreTests/             # 문서 저장, PDF 변환 및 동기화 관련 테스트
Tests/Resources/       # 테스트용 PDF fixture
```

## 개발 및 빌드

필요한 도구 버전은 `.xcode-version`과 `.ruby-version`을 참고하세요. Xcode 프로젝트의 원본 설정은 `project.yml`입니다.

```sh
# Xcode 프로젝트 생성
xcodegen generate --spec project.yml

# 서명 없이 generic iOS 빌드
xcodebuild -project Jottre.xcodeproj \
  -scheme Jottre \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build

# 테스트 타깃 빌드
xcodebuild -project Jottre.xcodeproj \
  -scheme JottreTests \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build

# iOS 시뮬레이터에서 테스트 실행
xcodebuild test -project Jottre.xcodeproj \
  -scheme Jottre \
  -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M4)' \
  CODE_SIGNING_ALLOWED=NO
```

### IPA 생성

저장소 루트의 `build.sh`는 Release 빌드, `Payload/Jottre.app` 구성, `Jottre.ipa` 압축을 수행합니다.

```sh
./build.sh
```

이 스크립트는 자동 프로비저닝 갱신을 사용하며 마케팅 버전과 빌드 번호를 스크립트 안에서 지정합니다. 배포 전에 `MARKETING_VERSION`과 `CURRENT_PROJECT_VERSION` 값을 확인하고 Apple 개발자 계정의 서명 설정을 준비하세요. 생성 결과는 저장소 루트의 `Jottre.ipa`입니다.

## 라이선스

Jottre Note는 원본 프로젝트의 저작권 고지와 라이선스를 유지합니다. 이 프로젝트는 [GNU GPLv3](LICENSE)에 따라 배포됩니다.
