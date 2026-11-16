# 코드 및 UI 정리 내역

작업일: 2026-11-16

라이브러리의 화면 구성과 데이터 처리가 한 파일에 집중된 구조, 화면 갱신에 따라 반복되던 계산 및 파일 조회, 사용하지 않는 과거 앱 소스 복사본을 정리했다. 공통화는 실제로 중복 사용하던 메뉴와 정렬 방향 계산, 화면용 데이터 구성에 한정했다.

## 변경 전과 후

| 영역 | 변경 전 | 변경 후 |
| --- | --- | --- |
| 라이브러리 구조 | 화면, 동기화, 복구, 정렬, 생성 창이 2,989줄의 한 파일에 포함 | 화면·상태 관리·데이터 구성·정책·입력 창으로 분리 |
| 문서 목록 | 화면 갱신마다 필터링·정렬·그룹화 | 위치별 결과를 보관하고 스냅샷이나 정렬 변경 시 무효화 |
| 컬렉션 사이드바 | 각 행에서 활성 컬렉션 판별과 전체 목록 필터링 반복 | 스냅샷별 부모→자식 인덱스 구성 |
| 활성 컬렉션 판별 | 각 노드의 조상을 재귀적으로 다시 탐색 | 반복문과 결과 메모이제이션으로 노드별 결과 재사용 |
| 정렬 | 비교할 때마다 제목과 날짜를 조회 | 첨부파일별 정렬 메타데이터를 먼저 계산 |
| 설정의 로컬 문서 | 렌더링 중 존재 확인·정렬·용량 조회 반복 | 갱신 시 목록·용량·오프로드 가능 키를 함께 계산 |
| UI | 목록 첫 행에 제목과 모든 작업 버튼 배치 | 탐색 막대에 제목과 작업 버튼 배치 |
| 과거 소스 | 테스트 폴더에 이전 앱 구현 145개 잔존 | 미사용 Swift 복사본 11,614줄 삭제, 실제 테스트·검증 자료 보존 |

## 코드의 새 위치

| 파일 | 책임 |
| --- | --- |
| [ZoteroLibraryView.swift](../Sources/WebDAV/ZoteroLibraryView.swift) | 라이브러리와 사이드바, 도구 막대, 선택 작업, 화면 표시 상태 |
| [ZoteroLibraryViewModel.swift](../Sources/WebDAV/ZoteroLibraryViewModel.swift) | 동기화, 문서 열기·생성·복구 및 화면용 데이터 캐시 |
| [ZoteroLibraryProjection.swift](../Sources/WebDAV/ZoteroLibraryProjection.swift) | 위치별 필터링, 정렬, 문서 그룹화, 첨부파일 표시 상태 |
| [ZoteroLibraryPolicies.swift](../Sources/WebDAV/ZoteroLibraryPolicies.swift) | 동기화 실행 간격, 다운로드 설치 순서, 로컬 기준본 판별 |
| [ZoteroLibrarySheets.swift](../Sources/WebDAV/ZoteroLibrarySheets.swift) | 문서 생성, PDF 등록, 메타데이터 편집, 컬렉션 선택 창 |
| [ZoteroLibrarySorting.swift](../Sources/WebDAV/ZoteroLibrarySorting.swift) | 저장 가능한 정렬 설정과 공통 정렬 방향 계산 |
| [ZoteroLocalDocumentInventory.swift](../Sources/SettingsPage/ZoteroLocalDocumentInventory.swift) | 로컬 문서 목록·파일 크기·오프로드 가능 여부의 화면용 스냅샷 |

라이브러리 화면 파일은 802줄로 줄었다. 상태 관리에는 기존 동기화·충돌 복구 흐름을 유지했다. 이 단계에서 범용 저장소나 새로운 DI 프레임워크를 추가하지 않았다.

## 계산 및 파일 접근

### 라이브러리와 컬렉션

문서 그룹은 탐색 위치별로 보관한다. 첨부파일·항목·컬렉션 등이 포함된 스냅샷이 바뀌면 그룹과 컬렉션 인덱스를 모두 폐기한다. 정렬 설정만 바뀌면 그룹만 폐기한다. 따라서 선택 표시나 열기 진행 상태 변경으로 동일한 문서를 다시 정렬하지 않는다.

활성 컬렉션 판별은 각 노드의 결과를 재사용한다. 조상 경로를 매번 따라가던 최악의 O(n × 깊이) 탐색을 O(n) 탐색으로 바꾸고 재귀 호출도 제거했다. 삭제된 조상, 존재하지 않는 부모, 자기 참조와 순환 참조는 계속 비활성으로 처리한다. 이름이 같은 컬렉션에는 키로 보조 정렬을 적용했다.

문서 정렬의 복잡도는 여전히 O(n log n)이다. 다만 제목과 날짜를 비교 함수 안에서 반복 조회하지 않는다. 첨부파일 날짜를 우선하고 없으면 부모 항목 날짜를 사용한다. 날짜 없는 문서는 양방향 정렬 모두 마지막에 배치하며, 동일 날짜는 제목과 키로 정렬한다. 제목이 같을 때 키의 직접 비교를 사용해 순서를 결정한다.

### 로컬 문서 설정

기존에는 여러 computed property와 각 행이 디스크를 조회했다. 이제 설정 진입, 캐시 변경 알림, 오프로드 결과 반영 시 파일 정보를 읽어 보관하고, 렌더링과 선택 변경은 이 결과를 사용한다. 일반 파일이 아닌 경로와 사라진 파일은 목록에서 제외한다.

저장 대기 상태인 `.dirty` 문서는 오프로드 가능 키에서 제외한다. 갱신 시 선택 집합과 오프로드 가능 키의 교집합만 남겨, 저장 대기 상태로 바뀌었거나 사라진 항목이 선택 목록에 남지 않도록 한다. 실제 삭제 판단은 기존 저장소의 오프로드 검증을 따른다.

## UI 변경

- 제목과 사이드바 표시·선택·정렬·추가 작업을 탐색 막대로 옮겼다. 스크롤하거나 문서가 없는 경우에도 버튼에 접근할 수 있다.
- 문서 목록에 시스템 그룹형 배경과 여백을 적용했다. 부모 문서 제목과 작성자·연도는 상위 정보로 유지한다.
- 첨부파일은 문서 아이콘, 파일 이름, 다운로드·저장 대기 상태의 두 단계 텍스트로 표시한다.
- 사이드바의 현재 위치에 강조색을 적용하고, 선택된 컬렉션에는 채워진 폴더 아이콘과 접근성 선택 속성을 적용했다.
- 선택 작업 막대는 아이콘 버튼으로 간결하게 표시한다. 접근성 이름과 삭제 확인 절차는 유지한다.
- 그룹 하단과 문맥 메뉴의 PDF·노트 추가 메뉴를 같은 구현으로 통합했다.
- 설정의 로컬 문서 행에도 문서 아이콘과 제목·부가 정보 위계를 적용했다.

기존 현지화 문자열과 시스템 색상을 사용했다. 실제 기기에서의 배치, 다크 모드, 큰 글자 크기 및 VoiceOver 동작은 별도 확인이 필요하다.

## 미사용 복사본 정리 근거

[project.yml](../project.yml)은 앱에 [Sources/](../Sources/), 단위 테스트에 [CoreTests/](../CoreTests/), UI 테스트에 [InteractionUITests/](../InteractionUITests/), 검증 자료에 [Tests/Resources/](../Tests/Resources/)만 포함한다.

삭제한 과거 Swift 파일 145개는 이 타깃들에 포함되지 않았으며 XCTest/Swift Testing 선언도 없었다. 저장소 참조를 확인한 뒤 이 파일들만 삭제했다. PDF와 Jot 검증 자료 2개는 그대로 보존했다. 과거 구현은 Git 이력에서 확인할 수 있다.

## 검증 결과

환경: Xcode 27.2, Swift 6, iOS/iPadOS 18 이상 프로젝트.

| 검증 | 결과 |
| --- | --- |
| generic iOS 앱 Debug 빌드, 서명 비활성화 | 통과; 미사용 파일 삭제 이후에도 재확인 |
| 신규 테스트 2개 파일의 iOS Simulator 타깃 `build-for-testing` | 통과; 나머지 기존 테스트 파일은 이 검증 명령에서 제외 |
| Foundation 코드의 임시 macOS 하네스 테스트 | 7개 실행, 실패 0개 |
| 편집한 UI·목록 코드의 에디터 진단 | 오류 없음 |
| `git diff --check` | 통과 |
| 전체 기존 단위 테스트 타깃 | 기존 API 불일치로 컴파일 실패 |
| iOS UI 테스트 및 기기 화면 확인 | 실행 가능한 시뮬레이터가 없어 미실행 |

새 테스트는 [ZoteroLibraryProjectionTests.swift](../CoreTests/ZoteroLibraryProjectionTests.swift)와 [ZoteroLocalDocumentInventoryTests.swift](../CoreTests/ZoteroLocalDocumentInventoryTests.swift)에 있다. 순환·고아·삭제 컬렉션, 10,000단계 컬렉션, 날짜 우선순위와 누락 날짜, 정렬과 그룹 순서, 휴지통 필터, 로컬 파일 용량과 저장 대기 문서 보호를 검증한다.

macOS 하네스는 이번 작업의 Git 제외 빌드 디렉터리에 임시 생성했다. 저장소 파일의 Foundation 모델 선언부에서 PDFKit import만 제거하고, 정렬·목록 구성·Defaults 구현과 신규 테스트를 그대로 복사해 실행했다. 따라서 순수 로직의 실제 실행 결과이며, PDFKit/PencilKit/SwiftUI 통합 테스트나 iOS 테스트 실행 결과를 의미하지 않는다.

전체 테스트의 기존 실패 사례:

- [ZoteroRecoveryBackupTests.swift](../CoreTests/ZoteroRecoveryBackupTests.swift): 현재 없는 `ZoteroRemoteRestoreEligibility`, 저장소 초기화·복구 설치 API를 참조한다. 변경 전 빌드에서 확인했다.
- [ArchitectureRefactoringTests.swift](../CoreTests/ArchitectureRefactoringTests.swift): 현재 메서드에 없는 `pickerVisible` 인수를 전달한다.
- [CanvasTouchRoutingTests.swift](../CoreTests/CanvasTouchRoutingTests.swift): 현재 없는 `JotEditMenuInteractionController` 및 `pickerVisible` 인수를 참조한다.

위 항목은 실제 테스트 파일로 보존했다. 테스트 전체 성공 여부는 이 불일치를 정리하고 시뮬레이터 런타임을 준비한 뒤 다시 확인해야 한다.

### 사용한 검증 명령

```sh
xcodegen generate --spec project.yml

xcodebuild -project Jottre.xcodeproj -scheme Jottre \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/RefactorValidation CODE_SIGNING_ALLOWED=NO build

# 신규 회귀 테스트만 iOS SDK로 컴파일한다.
# 전체 테스트가 통과한다는 의미가 아니다.
test_exclusions=$(rg --files CoreTests | sed \
  '/ZoteroLibraryProjectionTests.swift$/d; /ZoteroLocalDocumentInventoryTests.swift$/d; s|.*/||' \
  | tr '\n' ' ')
xcodebuild -project Jottre.xcodeproj -scheme JottreTests \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/RefactorValidation CODE_SIGNING_ALLOWED=NO \
  "EXCLUDED_SOURCE_FILE_NAMES=$test_exclusions" build-for-testing

# 이번 작업 중 생성한 임시 하네스가 존재하는 로컬 환경에서 실행 가능
swift test --package-path build/LibraryCoreValidation
```

## 실제 기기에서 확인할 항목

1. 문서가 없는 라이브러리에서 사이드바·추가·정렬 버튼에 접근한다.
2. 중첩 컬렉션 선택과 문서 그룹 펼치기, 첨부파일 열기를 확인한다.
3. 정렬 기준과 방향을 변경하고 메타데이터 수정·동기화 후 목록이 갱신되는지 확인한다.
4. 여러 문서를 선택해 이동·휴지통·복원을 실행하고 삭제 확인이 표시되는지 확인한다.
5. 설정에서 로컬 파일 용량, 저장 대기 상태, 선택 및 전체 오프로드를 확인한다.
6. PDF 열기·필기·저장과 충돌 복구를 실제 기기에서 회귀 확인한다.
