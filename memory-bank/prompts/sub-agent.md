# Sub-Agent Protocol

이 파일은 sub-agent가 작업 시작 전에 읽어야 하는 프로토콜이다.

---

## 입력 계약 (Orchestrator로부터 받는 것)

| 필드 | 필수 | 설명 |
|------|------|------|
| `Component` | ✅ | 구현/수정할 대상 이름 |
| `Action` | ✅ | `implement` / `fix` / `audit` 중 하나 |
| `Source` | ✅ | 참고할 파일 경로 또는 스펙 |
| `Context` | 선택 | 추가 설명 |

---

## 작업 프로토콜

### 1단계 — 지식 읽기

```
memory-bank/knowledge/RULES.md           → 반드시 따라야 할 규칙
memory-bank/knowledge/PATTERNS.md        → 재사용할 코드 패턴
memory-bank/knowledge/design-document.md → 설계 명세
memory-bank/CACHE.md                     → 최근 발견사항
```

### 2단계 — 작업 실행

- 소스 파일에서 **정확한 값을 직접 추출**한다 (시각적 추측, 임의 가정 금지)
- `RULES.md`의 원칙 (오프라인 우선, 분산화, 배터리 효율)을 항상 확인
- `PATTERNS.md`의 패턴을 그대로 적용한다

### 3단계 — 결과 보고

발견사항을 `memory-bank/CACHE.md`에 추가한 뒤 아래 형식으로 반환:

```markdown
## Sub-Agent Return: {Component}

### Code
{생성/수정한 파일 목록}

### Findings
| 유형 | 발견사항 | 조치 |
|------|----------|------|

### Confidence
{0-100}% — {이유}

### Notes
{orchestrator를 위한 추가 맥락}
```

---

## 반환 전 체크리스트

- [ ] `knowledge/` 파일들을 모두 읽었다
- [ ] RULES.md의 5가지 원칙을 위반하지 않았다
- [ ] 소스 데이터에서 직접 추출한 값만 사용했다
- [ ] 발견사항을 `CACHE.md`에 추가했다
- [ ] Confidence 수치와 근거를 명시했다
