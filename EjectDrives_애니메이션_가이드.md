# EjectDrives 메뉴바 캐릭터 애니메이션 구현 가이드

> 작성일: 2026-05-03
> 작성: Claude (with yongZa)
> 대상: macOS 13+ / Swift 5.9+ / AppKit
> 관련 문서: `EjectDrives_분석.md` (섹션 9), `EjectDrives_개발기획서.md` (섹션 6.5)

---

## 목차

1. 개요 및 결정 사항
2. 애셋 준비
3. Xcode 프로젝트 통합
4. 구현 방법 비교
5. Core Animation 구현 (권장)
6. 메뉴바 통합
7. 인터랙션별 애니메이션
8. 성능 최적화
9. 디버깅·테스트
10. 개발 워크플로우
11. 참고 라이브러리
12. 체크리스트

---

## 1. 개요 및 결정 사항

### 1.1 목표
- 메뉴바 22×22 pt 영역에 Tako 마스코트 애니메이션 표시
- 평상시 부드러운 호흡 애니메이션
- 단축키 발동 시 흔들림 + 방귀 파티클
- 추출 진행 시 다리 변화
- CPU 0.5% 미만, 메모리 50 MB 미만

### 1.2 기술 결정
- **렌더링**: Core Animation (CALayer)
- **애셋 형식**: PNG 시퀀스 (Retina 대응)
- **프레임 수**: 8~12 프레임 (idle), 인터랙션별 별도
- **fps**: 10 fps (idle), 60 fps (인터랙션)

---

## 2. 애셋 준비

### 2.1 형식 비교

| 형식 | 장점 | 단점 | 추천 |
|---|---|---|---|
| PNG 시퀀스 | 프레임 제어, GPU 친화 | 파일 여러 개 | ★ |
| APNG / GIF | 단일 파일 | 제어 어려움, GPU 비효율 | △ |
| SVG + Lottie | 벡터, 작은 크기 | 학습 곡선, 메뉴바엔 과함 | ✗ |

→ **PNG 시퀀스 채택**.

### 2.2 해상도

Retina 대응 필수:

| 디스플레이 | 파일명 규칙 | 픽셀 크기 |
|---|---|---|
| Standard | `tako_idle_0.png` | 22×22 |
| Retina (2x) | `tako_idle_0@2x.png` | 44×44 |
| Retina (3x) | `tako_idle_0@3x.png` | 66×66 |

Xcode `Assets.xcassets`에 드래그하면 자동 매칭.

### 2.3 디자인 가이드

- **루프 매끄러움**: 첫 프레임과 마지막 프레임이 자연스럽게 이어지도록
- **투명 배경**: PNG alpha channel 활용
- **다크/라이트 모드**: 두 가지 옵션
  - 옵션 A: 모드별 별도 에셋 (`tako_idle_0_dark.png`)
  - 옵션 B: **템플릿 이미지** (`isTemplate = true`) — macOS가 자동 색반전 (단색일 때만 적합)
- **여백 최소화**: 22pt 안에 캐릭터 꽉 채우기 (메뉴바 시인성)

### 2.4 폴더 구조 (디자이너 작업물)

```
Tako_Assets/
├── 01_Idle/                    # 평상시 호흡 애니메이션
│   ├── tako_idle_0.png ~ 7.png (각각 1x/2x/3x)
├── 02_Shake/                   # 단축키 발동 흔들림
│   ├── tako_shake_0.png ~ 5.png
├── 03_Eject/                   # 추출 중 다리 변화
│   ├── tako_legs_8.png         # 다리 8개
│   ├── tako_legs_7.png         # 다리 7개
│   └── ... tako_legs_0.png
└── 04_Special/                 # 진화 단계별 캐릭터
    ├── egg.png                 # 0개 (알)
    ├── tadpole.png             # 1개 (올챙이)
    └── ...
```

---

## 3. Xcode 프로젝트 통합

### 3.1 Asset Catalog 구성

```
Assets.xcassets/
├── TakoIdle/                   # Image Set
│   ├── tako_idle_0 (1x/2x/3x)
│   └── ... 0~7
├── TakoShake/
└── TakoLegs/
```

### 3.2 Image Set vs 파일 직접 로드

**Image Set 사용 (권장)**
```swift
let image = NSImage(named: "tako_idle_0")
```

**파일 직접 로드 (특수 경우)**
```swift
let url = Bundle.main.url(forResource: "tako_idle_0", withExtension: "png")!
let image = NSImage(contentsOf: url)
```

→ Image Set이 Retina 자동 매칭 + 빌드 최적화 받음.

---

## 4. 구현 방법 비교

### 4.1 옵션 A: NSImageView + Timer (가장 간단)

```swift
class SimpleMascotView: NSView {
    private let imageView = NSImageView()
    private var frames: [NSImage] = []
    private var timer: Timer?
    private var currentFrame = 0
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }
    
    private func setup() {
        frames = (0..<8).compactMap { NSImage(named: "tako_idle_\($0)") }
        imageView.frame = bounds
        addSubview(imageView)
        startAnimation()
    }
    
    func startAnimation() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.imageView.image = self.frames[self.currentFrame]
            self.currentFrame = (self.currentFrame + 1) % self.frames.count
        }
    }
    
    func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }
}
```

**장점**: 코드 간단, 이해 쉬움
**단점**: 메인 스레드 사용, GPU 가속 X, Timer 정확도 낮음

### 4.2 옵션 B: Core Animation (권장)

GPU 가속, 부드러움, 리소스 효율 모두 우월. 5장에서 상세 설명.

### 4.3 결정

→ **Core Animation (옵션 B)** 채택. 200줄도 안 되는 코드로 RunCat 수준 품질 확보 가능.

---

## 5. Core Animation 구현 (권장)

### 5.1 기본 마스코트 뷰

```swift
import Cocoa
import QuartzCore

class TakoMascotView: NSView {
    
    // MARK: - Properties
    
    private var spriteLayer: CALayer!
    private var idleFrames: [CGImage] = []
    private var isAnimating = false
    
    // MARK: - Init
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true   // 필수
        setupSprite()
    }
    
    required init?(coder: NSCoder) { 
        fatalError("init(coder:) not implemented") 
    }
    
    // MARK: - Setup
    
    private func setupSprite() {
        // 1. 프레임 사전 로드 (메모리 캐시)
        idleFrames = loadFrames(prefix: "tako_idle_", count: 8)
        
        // 2. 레이어 구성
        spriteLayer = CALayer()
        spriteLayer.frame = bounds
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.contents = idleFrames.first
        layer = spriteLayer
        
        // 3. Retina 대응
        spriteLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    }
    
    private func loadFrames(prefix: String, count: Int) -> [CGImage] {
        return (0..<count).compactMap { i in
            guard let img = NSImage(named: "\(prefix)\(i)") else { return nil }
            var rect = NSRect(origin: .zero, size: img.size)
            return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
    }
    
    // MARK: - Idle Animation
    
    func startIdleAnimation() {
        guard !isAnimating else { return }
        isAnimating = true
        
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = idleFrames
        animation.duration = 0.8                    // 8 프레임 × 0.1초
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete       // 스프라이트는 보간 X
        animation.isRemovedOnCompletion = false
        
        spriteLayer.add(animation, forKey: "idle")
    }
    
    func stopAnimation() {
        spriteLayer.removeAllAnimations()
        isAnimating = false
    }
}
```

### 5.2 핵심 포인트

1. **`wantsLayer = true`** — NSView가 CALayer를 사용하도록 활성화
2. **`calculationMode = .discrete`** — 프레임 사이 보간 끔 (스프라이트 정석)
3. **`contentsScale`** — Retina 디스플레이에서 선명하게 표시
4. **프레임 사전 로드** — 매 프레임마다 디스크 I/O 일어나면 안 됨

---

## 6. 메뉴바 통합

### 6.1 StatusItem 셋업

```swift
import Cocoa

class StatusItemController {
    
    private var statusItem: NSStatusItem!
    private var mascotView: TakoMascotView!
    
    func setup() {
        // 1. StatusItem 생성
        statusItem = NSStatusBar.system.statusItem(withLength: 28)
        
        // 2. 마스코트 뷰 추가
        let frame = NSRect(x: 3, y: 3, width: 22, height: 22)
        mascotView = TakoMascotView(frame: frame)
        statusItem.button?.addSubview(mascotView)
        
        // 3. 클릭 동작
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.target = self
        
        // 4. 애니메이션 시작
        mascotView.startIdleAnimation()
    }
    
    @objc private func handleClick() {
        // 드롭다운 메뉴 표시
        showDropdownMenu()
    }
    
    private func showDropdownMenu() {
        // ... 메뉴 구성
    }
    
    // 외부에서 인터랙션 트리거
    func triggerEjectAnimation() {
        mascotView.playShakeAndFart()
    }
}
```

### 6.2 주의사항

- `statusItem.button?.image`을 직접 설정하면 마스코트 뷰가 가려짐. **subview로 추가**.
- 메뉴바 height는 보통 22 pt 고정. width는 가변.
- 클릭 영역은 button 전체이므로 마스코트 위 클릭도 동작.

---

## 7. 인터랙션별 애니메이션

### 7.1 단축키 발동 — 흔들림 + 파티클

```swift
extension TakoMascotView {
    
    func playShakeAndFart() {
        playShake()
        playFartParticles()
        SoundPlayer.play(.fart)
    }
    
    // 흔들림
    private func playShake() {
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -3, 3, -2, 2, -1, 1, 0]
        shake.duration = 0.3
        shake.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        spriteLayer.add(shake, forKey: "shake")
    }
    
    // 💨 파티클 3개
    private func playFartParticles() {
        for i in 0..<3 {
            let particle = createFartParticle()
            let xOffset = CGFloat(i - 1) * 5  // -5, 0, 5 분산
            particle.position = CGPoint(
                x: bounds.midX + xOffset,
                y: bounds.minY
            )
            spriteLayer.addSublayer(particle)
            
            let delay = Double(i) * 0.08
            animateParticle(particle, delay: delay)
        }
    }
    
    private func createFartParticle() -> CATextLayer {
        let particle = CATextLayer()
        particle.string = "💨"
        particle.fontSize = 10
        particle.frame = CGRect(x: 0, y: 0, width: 14, height: 14)
        particle.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        particle.alignmentMode = .center
        return particle
    }
    
    private func animateParticle(_ layer: CALayer, delay: TimeInterval) {
        // 위로 떠오름
        let rise = CABasicAnimation(keyPath: "position.y")
        rise.fromValue = layer.position.y
        rise.toValue = layer.position.y + 18
        
        // 페이드 아웃
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        
        // 약간 흔들리며
        let drift = CAKeyframeAnimation(keyPath: "position.x")
        drift.values = [
            layer.position.x,
            layer.position.x + 2,
            layer.position.x - 2,
            layer.position.x
        ]
        
        let group = CAAnimationGroup()
        group.animations = [rise, fade, drift]
        group.duration = 0.6
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        
        layer.add(group, forKey: "particle")
        
        // 끝나면 제거
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.6) { [weak layer] in
            layer?.removeFromSuperlayer()
        }
    }
}
```

### 7.2 추출 중 — 다리 변화

```swift
extension TakoMascotView {
    
    /// 추출 진행에 따라 다리 개수 표시 (옵션 1: 캐릭터 PNG 교체)
    func updateLegCount(_ count: Int) {
        let clamped = max(0, min(8, count))
        guard let image = NSImage(named: "tako_legs_\(clamped)") else { return }
        
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &rect,
            context: nil,
            hints: nil
        ) else { return }
        
        // 부드러운 전환
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.2
        spriteLayer.add(transition, forKey: "legChange")
        spriteLayer.contents = cgImage
    }
    
    /// 추출 시퀀스: 다리 1개씩 사라짐
    func playEjectSequence(driveCount: Int, completion: @escaping () -> Void) {
        for i in 0..<driveCount {
            let delay = Double(i) * 0.15
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                let remaining = driveCount - i - 1
                self?.updateLegCount(remaining)
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(driveCount) * 0.15 + 0.3) {
            completion()
        }
    }
}
```

### 7.3 진화 단계 변화 — 캐릭터 교체

```swift
extension TakoMascotView {
    
    enum EvolutionStage {
        case egg, tadpole, threeOctopus, starfish, tako
        // ... 9.6.2 표 참고
        
        var imageName: String {
            switch self {
            case .egg: return "stage_egg"
            case .tadpole: return "stage_tadpole"
            case .threeOctopus: return "stage_three_octopus"
            case .starfish: return "stage_starfish"
            case .tako: return "stage_tako"
            }
        }
    }
    
    func evolveTo(_ stage: EvolutionStage) {
        guard let image = NSImage(named: stage.imageName) else { return }
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &rect,
            context: nil,
            hints: nil
        ) else { return }
        
        // 페이드 + 살짝 확대 효과
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.4
        spriteLayer.add(fade, forKey: "evolution")
        
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.2
        scale.duration = 0.2
        scale.autoreverses = true
        spriteLayer.add(scale, forKey: "evolutionScale")
        
        spriteLayer.contents = cgImage
        
        // 새 idle 프레임 로드 (스테이지별로 다른 idle 애니메이션)
        loadIdleForStage(stage)
    }
    
    private func loadIdleForStage(_ stage: EvolutionStage) {
        // 각 스테이지마다 idle 프레임 시퀀스 다름
        // ...
    }
}
```

---

## 8. 성능 최적화

### 8.1 유휴 시 정지

메뉴바 가려진 상태(풀스크린 앱 등)에서는 애니메이션 정지.

```swift
extension TakoMascotView {
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeOcclusion()
    }
    
    private func observeOcclusion() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
    }
    
    @objc private func occlusionChanged() {
        guard let window = self.window else { return }
        if window.occlusionState.contains(.visible) {
            startIdleAnimation()
        } else {
            stopAnimation()
        }
    }
}
```

### 8.2 저전력 모드 감지

```swift
extension TakoMascotView {
    
    func startIdleAnimation() {
        // 저전력 모드 시 애니메이션 끔
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            spriteLayer.contents = idleFrames.first
            return
        }
        
        // 일반 모드 애니메이션
        // ...
    }
}
```

### 8.3 프레임 사전 로드 시점

앱 시작 시 한 번만 로드:

```swift
class TakoAssetCache {
    static let shared = TakoAssetCache()
    
    let idleFrames: [CGImage]
    let shakeFrames: [CGImage]
    let evolutionStages: [String: CGImage]
    
    private init() {
        idleFrames = TakoAssetCache.load(prefix: "tako_idle_", count: 8)
        shakeFrames = TakoAssetCache.load(prefix: "tako_shake_", count: 6)
        evolutionStages = TakoAssetCache.loadEvolutions()
    }
    
    private static func load(prefix: String, count: Int) -> [CGImage] {
        return (0..<count).compactMap { i in
            guard let img = NSImage(named: "\(prefix)\(i)") else { return nil }
            var rect = NSRect(origin: .zero, size: img.size)
            return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
    }
    
    private static func loadEvolutions() -> [String: CGImage] {
        // ...
        return [:]
    }
}
```

### 8.4 성능 목표선

| 항목 | 목표 |
|---|---|
| CPU (idle) | < 0.5% |
| CPU (애니메이션 중) | < 2% |
| 메모리 | < 50 MB |
| Energy Impact | Low |
| 배터리 8시간 영향 | < 1% |

---

## 9. 디버깅·테스트

### 9.1 Xcode Instruments

**측정 항목**:
- **Energy Log**: Energy Impact 컬럼 — Low 유지
- **Time Profiler**: 메인 스레드 점유율 확인
- **Core Animation**: 프레임 드롭(frame drop) 없는지
- **Allocations**: 메모리 누수 검출

### 9.2 실기기 테스트 체크리스트

- [ ] 배터리 모드 8시간 운영 후 잔량 비교
- [ ] 외부 디스플레이 연결 시 정상 표시
- [ ] 다크/라이트 모드 둘 다 자연스러운지
- [ ] 멀티 모니터 환경에서 메뉴바 위치 변경 시 정상
- [ ] 스플릿 뷰 / 풀스크린 모드 시 애니메이션 정지
- [ ] 시스템 잠자기 → 깨어남 시 애니메이션 정상 재개
- [ ] 저전력 모드 토글 시 동작 확인
- [ ] Retina / Non-Retina 디스플레이 둘 다 선명한지
- [ ] 메뉴바 다른 앱 아이콘과 시각적 충돌 없는지

### 9.3 흔한 문제 디버깅

| 증상 | 원인 | 해결 |
|---|---|---|
| 애니메이션 안 보임 | `wantsLayer = false` | `wantsLayer = true` 설정 |
| 흐릿함 | `contentsScale` 미설정 | `NSScreen.backingScaleFactor` 적용 |
| 프레임 끊김 | 메인 스레드 블록 | I/O 작업 백그라운드로 |
| CPU 폭발 | Timer로 매번 NSImage 생성 | CGImage 사전 캐시 |
| 메모리 누수 | strong reference cycle | `[weak self]` 사용 |

---

## 10. 개발 워크플로우

### 10.1 1인 개발자 기준 일정

| 단계 | 작업 | 도구 | 시간 |
|---|---|---|---|
| 1 | 캐릭터 디자인 | Procreate / Figma / 외주 | 1~3일 |
| 2 | 프레임 export | Photoshop / Figma / Aseprite | 0.5일 |
| 3 | Asset Catalog 통합 | Xcode | 0.5일 |
| 4 | TakoMascotView 구현 | Core Animation | 1일 |
| 5 | 인터랙션 구현 | Core Animation | 1~2일 |
| 6 | 최적화·테스트 | Instruments | 0.5일 |

**총 4~7일** (Tako 캐릭터 1종 기준)

### 10.2 외주 발주 시 체크리스트

일러스트레이터에게 전달할 내용:

- [ ] 메뉴바 22×22 pt 사이즈 (디테일 한계 명시)
- [ ] Retina 1x/2x/3x 모두 export
- [ ] 투명 배경 PNG
- [ ] 다크/라이트 모드 대응 (단색 vs 컬러 결정)
- [ ] 프레임별 정확한 픽셀 위치 일관성 (캐릭터 흔들림 방지)
- [ ] idle / shake / leg-by-leg 애니메이션 시퀀스 분리
- [ ] 라이선스: 상업 사용 가능, 수정 권한 포함

추천 플랫폼:
- **국내**: 크몽, 숨고
- **해외**: Fiverr, Upwork
- **단가**: 캐릭터당 ₩30,000~80,000 (한국), $30~150 (해외)

---

## 11. 참고 라이브러리

### 11.1 Lottie-iOS
- **장점**: After Effects 애니메이션 → JSON → 자동 재생
- **단점**: 학습 곡선, 메뉴바엔 오버킬
- **결론**: ✗ 추천 안 함

### 11.2 SpriteKit
- **장점**: Apple 공식 게임 프레임워크
- **단점**: 게임용이라 메뉴바엔 무거움
- **결론**: ✗ 추천 안 함

### 11.3 GIF (NSImage)
```swift
let image = NSImage(named: "tako_animated.gif")
imageView.animates = true
```
- **장점**: 코드 0줄
- **단점**: GPU 비효율, 제어 불가
- **결론**: △ 프로토타입에는 OK, 출시판은 X

### 11.4 결론
→ **외부 라이브러리 없이 Core Animation 직접 구현** 이 메뉴바엔 정답.

---

## 12. 최종 체크리스트

### 12.1 출시 전 필수

- [ ] 1x/2x/3x Retina 에셋 모두 준비
- [ ] 다크/라이트 모드 양쪽 자연스러움 확인
- [ ] CPU 사용률 0.5% 미만 (Activity Monitor)
- [ ] Energy Impact "Low" 유지
- [ ] 메모리 50 MB 미만
- [ ] 메뉴바 가려질 때 애니메이션 정지
- [ ] 저전력 모드 시 애니메이션 끔
- [ ] 외부 디스플레이에서 정상 표시
- [ ] 8시간 배터리 영향 측정 완료
- [ ] 메모리 누수 없음 (Instruments Allocations)
- [ ] 모든 인터랙션 (idle / shake / eject) 60fps 유지

### 12.2 코드 품질

- [ ] `[weak self]` 누락 없음
- [ ] `removeAllAnimations()` 호출로 정리
- [ ] Asset 사전 로드 (런타임 디스크 I/O X)
- [ ] CGImage 캐시 (TakoAssetCache 활용)
- [ ] 단위 테스트 (애니메이션 상태 전환)

---

## 부록 A: 빠른 시작 (Minimum Viable Animation)

가장 간단한 동작 확인용 코드 (5분 내 빌드):

```swift
import Cocoa
import QuartzCore

class QuickTakoView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        
        guard let frames = (0..<4).compactMap({ NSImage(named: "tako_idle_\($0)") })
            .compactMap({ img -> CGImage? in
                var rect = NSRect(origin: .zero, size: img.size)
                return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            }) as? [CGImage] else { return }
        
        let layer = CALayer()
        layer.frame = bounds
        layer.contentsScale = 2.0
        self.layer = layer
        
        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.values = frames
        anim.duration = 0.5
        anim.repeatCount = .infinity
        anim.calculationMode = .discrete
        layer.add(anim, forKey: "idle")
    }
    required init?(coder: NSCoder) { fatalError() }
}
```

이게 동작하면 5장의 본격 구현으로 확장.

---

## 부록 B: 참고 자료

- Apple Developer: [Core Animation Programming Guide](https://developer.apple.com/documentation/quartzcore)
- Apple Developer: [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
- Apple Developer: [CALayer](https://developer.apple.com/documentation/quartzcore/calayer)
- 오픈소스 참고:
  - RunCat (소스 비공개, 동작 참고)
  - Bartender (메뉴바 UI 패턴)
  - Maccy (오픈소스, 메뉴바 통합 사례)

