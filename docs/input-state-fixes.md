# 페이지 전환 입력과 정렬 상태 수정

검증일: 2026-10-16

## 원인과 변경

| 문제 | 확인한 원인 | 적용 내용 |
| --- | --- | --- |
| 새 페이지의 텍스트 메뉴 | 편집 상태에서 PDFKit 또는 캔버스 responder가 표준 편집 액션을 허용할 수 있음 | 오버레이를 PDFKit에 반환하기 전에 편집 상태를 동기 적용하고 PDF/캔버스의 `canPerformAction`에서 표준 편집 액션 차단 |
| 올가미 손가락 입력 및 PDF 줌 | 올가미에 손가락 입력이 허용되거나 PDF 스크롤 제스처가 Pencil 입력을 받을 수 있음 | 모든 PencilKit 도구를 `.pencilOnly`로 설정하고 편집 중 PDF 팬에는 직접 터치만 허용. 페이지 캔버스 자체 줌은 꺼 PDFKit의 스크롤과 더블 탭 줌을 유지 |
| 입력 경합 | PDFKit 편집 모드 미설정 및 PDF 스크롤 탐색이 PencilKit 스크롤 계층까지 포함 | `isInMarkupMode`를 편집 상태에 연결하고 페이지 오버레이 전체를 PDF 제스처 변경 대상에서 제외하고 손가락 페이지 탐색을 한 손가락으로 유지 |
| 정렬/재실행 상태 | 정렬이 메모리 상태였고 저장된 scene activity가 이전 편집기를 재개 | `ZoteroLibrarySorting`이 정렬 기준·역순 여부를 한 UserDefaults 값으로 저장/복원. 일반 재실행은 라이브러리에서 시작 |

이동 동작은 PencilKit의 기본 동작을 사용한다. 앱은 PKStroke를 직접 이동하거나
올가미 경로를 가로채지 않는다. PDF 저장/내보내기 빌더와 고해상도 줌 좌표계는
이번 수정에서 변경하지 않았다.

## 주요 파일

- `Sources/EditJotPage/JotEditorGestureCoordinator.swift`, `CanvasTouchRouting.swift`: 입력 정책과 PDF 팬 입력.
- `Sources/EditJotPage/EditJotViewController.swift`, `CanvasTouchRouting.swift`: 페이지 바인딩과 responder 상태.
- `Sources/WebDAV/ZoteroLibrarySorting.swift`, `ZoteroLibraryView.swift`: 정렬 영속화 및 즉시 목록 갱신.
- `Sources/SceneLaunchPolicy.swift`, `SceneDelegate.swift`, `SceneCoordinator.swift`: 초기 탐색 상태.
- `CoreTests/EditorTransitionAndSortingTests.swift`: 신규 단위 테스트 13개.
- `InteractionUITests/`, `Sources/Testing/EditorInteractionFixture.swift`, `project.yml`: 별도 UI 테스트 타깃과 DEBUG 전용 문서 픽스처.

## 검증 결과

환경: iPad Air 11-inch (M4), iOS 26.5 Simulator, Xcode 27 SDK.

| 검증 | 결과 |
| --- | --- |
| `JottreTests` 전체 | **123 passed, 0 failures, 0 skipped** |
| `JottreInteractionUITests` 전체 | 기존 결과는 사용자 정의 finger-lasso 구현 대상이며 현재 동작 검증에 해당하지 않음 |
| generic iOS Release 앱 빌드 | **BUILD SUCCEEDED**, `CODE_SIGNING_ALLOWED=NO` |
| `xcodegen generate`, `git diff --check` | 성공 |

이전 UI 결과는 현재 올가미 동작의 검증 결과가 아니다. 정렬 검사는 앱
프로세스를 종료하고 재실행한 뒤 기준·방향을 비교했다. PencilKit의 네이티브
올가미 포인터 이동은 실기기 Apple Pencil 입력으로 별도 확인해야 한다.

- [단위 테스트 요약](../build/input-state-verification/unit-summary.json)
- [UI 테스트 요약](../build/input-state-verification/ui-summary.json)
- [Release 빌드 로그](../build/input-state-verification/release-build.log)

이번 변경에서 generic iOS Release 빌드는 통과했다. 실제 Apple Pencil 올가미와
더블 탭 줌 동작은 기기에서 확인해야 한다.

## 재실행 명령

```sh
xcodebuild test -scheme Jottre \
  -destination 'platform=iOS Simulator,id=9D2E7F97-79B4-44F1-B624-AF4B2C90EBB4' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO

xcodebuild test -scheme JottreInteractionUITests \
  -destination 'platform=iOS Simulator,id=9D2E7F97-79B4-44F1-B624-AF4B2C90EBB4' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO

xcodebuild -scheme Jottre -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```
