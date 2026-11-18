# macOS 입력기

| 규칙 | 적용 코드와 검증 |
| --- | --- |
| 실제 키를 보낸 입력창에 조합을 연결한다. 다른 창의 등록이나 늦은 비활성화가 현재 조합을 끊어서는 안 된다. | `NativeInputEngine.handleNative`이 출력을 연결한다. `refreshConfiguration`은 저장 패널만 받는다. `CoordinatorQA`가 두 입력창의 교차 호출을 검사한다. |
| 호스트가 처리한 삭제는 실제 키 이벤트를 `DirectInputTap.reset(afterHostKey:)`에 전달한다. | `NativeCaretReset`과 `NativeNotionOutput`의 커서 상태가 위치를 읽는 시점을 결정한다. `NativeNotionOutputQA`가 삭제 후 빠른 한글 입력과 이전 줄 보존을 검사한다. |
| 호스트에서 삭제한 뒤의 조합은 실제 출력 경로가 편집기에 남긴 문자열로 판정한다. | `scripts/test-direct-input.sh --native-editing`이 실제 이벤트 처리기와 IMK 출력 코드를 연결해, 커서 보고가 늦는 편집기에서 `가나`와 앞줄을 검사한다. |
