# macOS 입력기

| 규칙 | 적용 코드와 검증 |
| --- | --- |
| 실제 키를 보낸 입력창에 조합을 연결한다. 다른 창의 등록이나 늦은 비활성화가 현재 조합을 끊어서는 안 된다. | `NativeInputEngine.handleNative`이 출력을 연결한다. `refreshConfiguration`은 저장 패널만 받는다. `CoordinatorQA`가 두 입력창의 교차 호출을 검사한다. |
