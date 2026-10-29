# Apple Pencil 필기·도구 전환·PDF 맞춤 개선

작업 기준: 2026-10-22, 원격 main 및 작업 HEAD
`abffa41b783c82e9f0d2e1035ffd06fdbfbdd745`.
시작 시 존재한 저장·Zotero·빌드 스크립트 등의 미커밋 변경은 보존했다.

## 필기 처리

기존에는 drawing 콜백마다 현재 페이지를 문서 좌표로 변환하고, 다른
페이지까지 순회·재결합한 뒤, 전체 문서의 변경 시그니처와 저장 스냅샷을
생성했다. 디스크 쓰기만 디바운스해서 이 CPU 작업은 입력 중에도 반복됐다.
수동 스트로크 비교 역시 모든 필압 샘플을 방문했다.

이제 네이티브 PencilKit이 중간 샘플을 렌더링하며, 콜백은 hold 관찰과
변경 표시만 수행한다. 도구 종료 후 콜백을 병합하여 현재 페이지만 커밋한다.
올가미·지우개·Undo 콜백도 병합하며, 화면 종료·백그라운드·오버레이 해제 시
마지막 네이티브 드로잉을 강제로 반영한다.

`JotEditorDrawingState`는 페이지별 `PKDrawing`과 revision을 유지한다.
다른 페이지를 순회하지 않고 교체하며, 전체 문서는 저장·내보내기·페이지
구조 변경 시 결합한다. 페이지 내 스트로크 순서와 기존 marker-first 저장
순서를 유지한다. 기존 단일 드로잉 `.jot` 포맷을 바꾸지 않는다.

수동 `strokesMatch`는 제거했다. 네이티브 drawing equality만 이용하고,
독립적으로 재구성된 값은 보수적으로 변경으로 취급한다. seed·bounds·포인트
수만으로 변경을 생략하지 않는다. 구조 변경용 `changedPages`에서도 seed를
키로 삼는 불완전한 비교를 제거했다.

Scribble Erase는 완료된 새 잉크에 대해 해당 페이지만 검사한다. 결과를
실제로 지울 때만 canvas에 재할당하고 페이지 Undo/Redo를 등록한다.
Draw-and-Hold의 기존 네이티브 제스처 관찰·완료 후 변환은 유지한다.

저장 예약은 dirty/revision만 갱신한다. 2초간 입력이 잠잠하고 Pencil이
내려가 있지 않을 때 최신 스냅샷 하나를 생성한다. MainActor에서 캡처한
불변 값을 기존 writer가 utility 작업으로 직렬 저장한다. 동일 revision의
중복 저장을 생략하고, 실패한 revision은 완료로 처리하지 않아 재시도한다.
종료·백그라운드 flush는 저장 중 새 변경이 생기면 최신 revision까지 기다린다.
기존 Zotero 편집 lease 및 에디터 종료 후 원격 업로드 정책은 유지한다.

### 재현 가능한 CPU 측정

Xcode 27.1 / iPad Air 11-inch (M4), iOS 26.5 Simulator / Debug.
10페이지에 스트로크를 분산하고, 스트로크마다 64개 필압 샘플을 사용했다.
동일한 `EditorInkPerformanceTests.testPageCommitScaling`으로 페이지 교체를
30회 반복한 평균이다. 수정 전은 실제 기존 구현, 수정 후는 변경 구현이다.

| 문서 스트로크 수 | 수정 전 페이지 교체 | 수정 후 페이지 교체 |
| --- | ---: | ---: |
| 0 | 0.0446 ms | 0.0127 ms |
| 100 | 1.2720 ms | 0.0055 ms |
| 500 | 6.0762 ms | 0.0027 ms |
| 1,000 | 12.0844 ms | 0.0050 ms |

전체 문서 결합을 저장 시점으로 옮긴 결과가 포함돼 있다. 이 수치는 전체
drawing 콜백, 저장, 프레임 시간 또는 실기기 Pencil 지연의 측정값이 아니다.
아주 짧은 측정은 워밍업·스케줄링 잡음의 영향을 받는다. 메모리 증가량과
느린 프레임 수, 장시간 실기기 필기 지연은 측정하지 못했다.

DEBUG 전용 Points of Interest signpost:
`DrawingCallback`, `CommitPageDrawing`, `DocumentDrawing`, `LocalDrawing`,
`ReplacePage`, `DrawingsMatch`, `ChangedPages`, `ScribbleErase`,
`CombineDocument`, `PersistenceSnapshot`.
제거된 `strokesMatch`에는 더 이상 실행 시간이 발생하지 않는다.

실기기에서는 Instruments의 Time Profiler와 Points of Interest로 빈 페이지,
100/500/1,000개 이상 스트로크, 여러 PDF 페이지, 확대 상태, Undo/Redo,
올가미, 로컬 저장 도중 필기를 각각 기록해야 한다. 콜백당 CPU 시간·메인
스레드 점유·hitch·메모리·저장 구간을 분리하여 비교한다.

## Apple Pencil 더블 탭

기존 선택은 inkType/eraserType만 맞춰 색상·굵기가 다른 도구를 구분하지
못했다. 지연·중복 observer 콜백이 이전 도구를 현재 도구로 덮어쓸 수도 있었다.

`JotToolSelectionHistory`는 전체 도구 값과 설치된 item identifier를 함께
기록한다. 동일 콜백은 history를 바꾸지 않는다. 프로그램 선택은 실제
picker 선택 성공을 확인하고 canvas/history를 즉시 동기화한다.
사용자 선택 콜백이 아직 처리되지 않은 상태의 하드웨어 탭도 먼저 반영한다.

변경된 동일 item의 설정은 read-only이므로 해당 item만 재구성하고 나머지
item, ruler, 색상 UI 상태를 유지한다. 구형 `selectedTool` setter는 custom
identifier에서 예외가 발생하는 것을 테스트 중 확인하여 사용하지 않았다.
`preferredTapAction`의 이전 도구/지우개 전환을 존중하며, 손가락 더블 탭은
별도의 기존 recognizer로 처리한다. DEBUG에서는 하드웨어 이벤트 수신 및
선택 실패를 기록한다.

시뮬레이터 테스트는 펜 A/B 동일 inkType, 다른 색상·굵기, 중복 콜백,
반복 이전 도구 교환, 펜→지우개→펜, 동일 item 설정 복원을 검증한다.
실제 Pencil 하드웨어 더블 탭은 연결 가능한 실기기가 없어 검증하지 못했다.

## PDF 맞춤

기존 배율은 PDFView 크기를 페이지 축으로 나눠 표시 너비를 모두 사용하고,
문서 스크롤 뷰의 inset과 페이지 여백을 고려하지 않았다. 작은 레이아웃
차이에도 가로 스크롤이 생기고, 맞는 축과 스크롤 가능한 축의 정렬 정책이
혼재할 수 있었다.

문서 UIScrollView의 `adjustedContentInset`을 뺀 표시 영역과 safe area의
교집합을 사용한다. 표시 box·회전·페이지 축 구분을 유지하며 가로 맞춤은
`viewportWidth × 0.97 / (displayedPageWidth + horizontalPageMargins)`이다.
세로 맞춤도 페이지 여백을 포함한다. PDFKit 레이아웃이 반영된 뒤 새 viewport를
다시 읽어, 맞는 축은 페이지 중앙에, 스크롤 가능한 축은 탭 위치에 정렬한다.
새 핀치가 시작되면 이전 맞춤의 후속 정렬을 무효화한다.

## 검증과 남은 확인

단위 테스트 139개 통과. 저장·Hybrid PDF·Zotero 충돌/편집 lease 회귀,
좌표·도형·hold·입력 정책 테스트를 포함한다. 새 테스트는 기존 `.jot`에서
페이지 저장소로의 호환성과 필압·기울기·마스크·좌표·순서 보존, 같은 seed의
필압/마스크/올가미 변경, 저장 실패 재시도와 동시 수정 flush를 검증한다.

Debug 시뮬레이터 테스트 빌드와 서명 없는 iOS Release 빌드 통과.
실기기는 등록되어 있지만 현재 unavailable 상태다. 실기기 장시간 필기,
하드웨어 더블 탭, 실제 올가미 선택·조작, 도구 항목 재구성 시 picker 표시의
연속성은 추가 확인이 필요하다. 전체 문서 결합은 저장 경계의 MainActor
작업으로 남아 있으므로, 초대형 문서의 저장 시 지연이 다음 최적화 대상이다.

## 수정 파일과 커밋 제안

프로덕션: `EditJotViewController`, `EditJotViewModel`, `EditJotRepository`의
writer, `JotEditorDrawingState`, `JotPageCanvasCoordinateAdapter`,
`ScribbleEraseProcessor`, `JotCanvasZoomCoordinator`, 새 `EditorInkPerformance`,
새 `JotToolSelectionHistory`, DEBUG `EditorInteractionFixture`.

테스트: 새 `EditorInkPerformanceTests`, `EditorPageDrawingStateTests`,
`EditorPagePersistenceTests`, `JotToolSelectionHistoryTests`, 기존
`JotCanvasZoomCoordinatorTests`, `EditorInteractionUITests`.
문서: 이 보고서 및 `editor-architecture.md`.

이번 요청에는 커밋 생성 지시가 없어 변경만 남겼다. 기존 미커밋 변경과
겹치는 파일은 hunk 단위로 분리하는 것이 적절하다.

1. `perf(editor): commit page ink after strokes and defer save snapshots`
2. `fix(editor): restore exact Pencil tool selections and history`
3. `fix(pdf): fit pages to the adjusted viewport with balanced margins`
