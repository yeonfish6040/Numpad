<p align="center">
  <img src="docs/images/icon.png" width="112" alt="Numpad 앱 아이콘">
</p>

<h1 align="center">Numpad</h1>

<p align="center"><strong>트랙패드가 숫자판이 되는 순간.</strong><br>키보드에 없는 숫자판을 더하는 macOS 메뉴 막대 앱.</p>

<p align="center">
  <a href="https://github.com/yeonfish6040/Numpad/releases/latest"><strong>Mac용 다운로드 ↓</strong></a>
  &nbsp; · &nbsp; <a href="README.md">English</a>
  &nbsp; · &nbsp; <a href="docs/DEVELOPMENT.md">개발 가이드</a>
</p>

<p align="center"><img src="docs/images/overlay.jpg" width="780" alt="Numpad 숫자판 오버레이"></p>

<kbd>오른쪽 ⌘</kbd> + <kbd>오른쪽 ⌥</kbd>를 눌렀다 놓고, 트랙패드를 탭하세요. 숫자와 연산자를 입력할 수 있습니다. 반투명 오버레이가 위치를 안내하고 햅틱이 입력을 알려줍니다.

## 직접 보기

[![숫자 입력과 손가락 보정을 보여주는 Numpad 시연](docs/images/demo.gif)](https://github.com/yeonfish6040/Numpad/releases/download/v0.0.4/Numpad-demo.mp4)

[시연 영상 보기 ↗](https://github.com/yeonfish6040/Numpad/releases/download/v0.0.4/Numpad-demo.mp4) · Mac에서 직접 녹화한 36초 분량의 숫자 입력·손가락 보정 영상입니다.

## 주요 기능

- **탭으로 입력:** 숫자, 소수점, 사칙연산, Return, Backspace. 짧게 탭하고 떼면 한 번 입력합니다.
- **손끝으로 확인:** 접촉 시작·입력 확정·`5` 중심 진입과 이탈의 햅틱을 각각 설정합니다.
- **원하는 위치에:** 오버레이를 드래그하고 화면 가장자리·중앙에 스냅합니다. 활성화할 때 입력창을 가리면 빈자리로 이동합니다.
- **편한 배치로:** 조작키를 왼쪽 또는 오른쪽에 둡니다. 한 손가락을 쉬게 둔 채 다른 손가락으로 반복 탭할 수 있습니다.
- **로컬에서 동작:** 계정, 네트워크 요청, 분석, 입력 기록 파일이 없습니다. 오버레이 배치를 위해 입력창의 위치를 확인하며 입력 내용은 읽지 않습니다.
- **영어·한국어 지원:** 기본 언어는 영어입니다. **Settings → General → Language → 한국어**에서 바로 바꿀 수 있습니다.

## 시작하기

1. **[최신 DMG](https://github.com/yeonfish6040/Numpad/releases/latest)**를 열고 **Numpad**를 **Applications**로 드래그합니다. 릴리즈 앱은 Developer ID 서명과 Apple 공증을 거칩니다.
2. 앱을 실행하고 **시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용**에서 권한을 허용합니다.
3. 입력할 칸을 선택한 뒤 **오른쪽 Command + 오른쪽 Option**을 눌렀다 놓습니다.
4. 원하는 키 위치를 탭합니다. **Esc** 또는 같은 단축키로 끕니다.

**macOS 13 이상과 Mac 트랙패드가 필요합니다.** Apple Silicon·Intel 공용이며, 햅틱은 Force Touch 트랙패드에서 지원합니다.

처음 실행하면 권한, 배치, 단축키, 입력 연습을 안내하는 가이드가 열립니다. 메뉴 막대의 **시작 가이드…**에서 언제든 다시 열 수 있으며 가이드 안에서 영어·한국어를 선택할 수 있습니다.

> 숫자판을 켜면 일반 트랙패드 포인터 이동과 스크롤을 차단합니다. 물리 클릭과 클릭 드래그는 통과합니다. 설정창을 열면 숫자판이 꺼집니다.

## 나에게 맞추기

**설정 → 일반**에서 언어와 조작키 위치를 바꿉니다. 오버레이를 드래그하면 위치가 저장되고 **하단 중앙으로 초기화**로 되돌릴 수 있습니다. **햅틱** 탭에서는 느끼고 싶은 피드백을 선택합니다.

<p align="center"><img src="docs/images/settings-en.jpg" width="46%" alt="언어와 조작키 배치 설정"> &nbsp; <img src="docs/images/haptics-en.jpg" width="46%" alt="햅틱 설정"></p>

<details>
<summary><strong>실험적 기능: 손가락에 맞춰 숫자판 보정</strong></summary>

**설정 → 실험적 → 손가락 위치로 좌표 보정**을 켜세요. 세 손가락을 동시에 대면 가운데 손가락에 `5`를 고정하고 양쪽 손가락으로 배치의 위치·회전·크기를 맞춥니다.

네 손가락 보정을 추가하면 가운데 두 손가락을 `×·−`에 맞출 수 있습니다. 보정은 조작키 방향별로 저장하며 다음 활성화에 유지할지 선택할 수 있습니다. 기본값은 꺼짐입니다.

활성 중 충돌하는 macOS 제스처를 차단하고 트랙패드·스크롤 확대 설정을 일시 중단하며, 모드 해제 시 이전 값으로 복원합니다. 크게 조정하면 일부 키가 트랙패드 밖으로 나갈 수 있습니다.

</details>

## 알아두기

- 단축키는 **오른쪽** Command·Option만 인식하며 Shift·Control을 추가하지 않아야 합니다. 보안 입력, 절전, 권한 철회, 입력 감시 중단 시 모드가 꺼집니다.
- 한 손가락을 약 120ms 이상 가만히 두면 기준 손가락이 됩니다. 기준 손가락을 떼거나 크게 움직이면 진행 중인 탭이 취소됩니다.
- Apple 비공개 API를 사용하므로 macOS 업데이트에 따라 호환성이 바뀔 수 있습니다. 기본 트랙패드를 사용하며 장치를 바꾸면 앱을 재실행하세요.
- 물리 클릭은 압력과 접촉 시점으로 구분합니다. 압력이 없는 외장 마우스를 트랙패드와 동시에 사용하면 탭 클릭으로 분류될 수 있습니다.
- 소수점과 키패드 단축키 해석은 대상 앱·입력 설정에 따라 달라질 수 있습니다.

## 직접 빌드하기

```sh
git clone https://github.com/yeonfish6040/Numpad.git
cd Numpad
swift test
bash scripts/build-app.sh
open dist/Numpad.app
```

Swift, AppKit, SwiftUI로 작성했으며 외부 패키지 의존성이 없습니다. 자세한 구조, 번역 추가, 진단 명령, 서명·공증 방법은 [개발 가이드](docs/DEVELOPMENT.md)에 정리했습니다.

문제나 제안은 [이슈](https://github.com/yeonfish6040/Numpad/issues)로 남겨주세요. Mac 모델, macOS 버전, 재현 단계를 함께 적어주시면 도움이 됩니다.
