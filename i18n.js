(() => {
  "use strict";

  const translations = {
    ko: {
      pageTitle: 'DiskOUT — 잠자기 전 자동 추출, "디스크가 제대로 추출되지 않음" 방지',
      pageDescription: 'Mac이 잠들기 전에 모든 외장 드라이브를 자동으로 추출하고 깨어나면 다시 마운트합니다. 무료, Apple 공증 완료, 4개 언어 지원.',
      language: "언어",
      appIconAlt: "DiskOUT 앱 아이콘",
      heroTitle: "아무것도 하지 마세요.<br>디스크는 안전하게 추출됩니다.",
      tagline: "Mac은 완벽합니다. 그 알림 하나만 빼면요. DiskOUT이 무료로 없애드립니다.",
      notification: '<s>"디스크가 제대로 추출되지 않음"</s><br><small>이제 다시 보지 않아도 됩니다.</small>',
      downloadMac: "Mac용 다운로드 →",
      viewGitHub: "GitHub에서 보기",
      requirements: "무료 · 약 4 MB · macOS 13+ · Apple Silicon · Apple 공증 완료",
      howTitle: "작동 방식",
      step1Title: '<span class="n">1.</span> 덮개를 닫으면 모든 드라이브를 안전하게 추출합니다.',
      step1Body: "닫기 → 추출. 열기 → 재마운트. 잠자기 → 추출. 깨우기 → 재마운트. 따로 할 일은 없습니다.",
      step2Title: '<span class="n">2.</span> 드라이브 10개도 한 번에 추출합니다.',
      step2Body: "단축키 한 번 또는 메뉴 막대 아이콘 우클릭 한 번이면 모두 추출됩니다.",
      step3Title: '<span class="n">3.</span> 연결된 드라이브 수를 바로 확인합니다.',
      step3Body: "메뉴 막대에 연결된 외장 드라이브 수가 실시간으로 표시됩니다.",
      demoTitle: "작동 화면",
      demoPlaceholder: "▶︎ 데모 준비 중 — 덮개 닫기 → 드라이브 추출 → 경고 없음 → 다시 열기 → 재마운트",
      safeTitle: "안전을 우선한 설계",
      feature1Title: "Time Machine 자동 보호",
      feature1Body: "백업 디스크는 자동 추출에서 제외되어 백업이 중단되지 않습니다.",
      feature2Title: '"제대로 추출되지 않음" 경고 방지',
      feature2Body: "잠자기 전에 정상 마운트 해제를 실행하므로 macOS가 경고하지 않습니다.",
      feature3Title: "디스크별 자동 추출 제외",
      feature3Body: "볼륨 UUID 기준이라 케이블이나 포트를 바꿔도 설정이 유지됩니다.",
      feature4Title: "광고·추적 없음",
      feature4Body: "업데이트 확인 외에는 외부 통신이 없습니다.",
      feature5Title: "Developer ID 및 공증 완료",
      feature5Body: 'Gatekeeper를 통과하므로 "확인되지 않은 개발자" 경고가 표시되지 않습니다.',
      feature6Title: "읽기·쓰기 활동 표시",
      feature6Body: "드라이브가 사용 중이면 파란 점으로 알려줍니다.",
      compareTitle: "DiskOUT과 대안 비교",
      macBuiltIn: "macOS 기본 기능",
      compareSleep: "잠자기 시 자동 추출",
      compareWake: "깨어날 때 자동 재마운트",
      compareAll: "한 번에 모두 추출",
      compareTM: "Time Machine 보호",
      price: "가격",
      free: "무료",
      compareNote: "무료 Jettison 대안을 찾고 있다면 DiskOUT이 핵심 기능을 모두 제공합니다.",
      faqTitle: "자주 묻는 질문",
      faq1Q: 'Mac의 "디스크가 제대로 추출되지 않음" 경고를 없애려면?',
      faq1A: "DiskOUT을 설치하세요. Mac이 잠들기 전에 모든 외장 드라이브를 정상 추출하고 깨어나면 다시 마운트하므로 경고가 발생하지 않습니다.",
      faq2Q: "정말 무료인가요?",
      faq2A: "네. 계정이나 로그인 없이 GitHub Releases에서 무료로 받을 수 있습니다.",
      faq3Q: "데이터가 손상될 수 있나요?",
      faq3A: "DiskOUT은 macOS 표준 추출 경로로 정상 마운트 해제를 먼저 시도합니다. 안전하게 추출할 수 없는 디스크는 그대로 두고 알림만 보냅니다.",
      faq4Q: "Intel Mac에서도 동작하나요?",
      faq4A: "현재 배포 빌드는 Apple Silicon(M1/M2/M3/M4) 전용이며 macOS 13 Ventura 이상이 필요합니다.",
      faq5Q: "Homebrew로 설치하려면?",
      downloadFree: "DiskOUT 무료 다운로드",
      feedback: "의견 보내기"
    },
    ja: {
      pageTitle: 'DiskOUT — スリープ前に自動取り出し、「ディスクの不正な取り出し」を防止',
      pageDescription: 'Macがスリープする前に外付けドライブを自動で取り出し、復帰時に再マウントします。無料、Apple公証済み、4言語対応。',
      language: "言語",
      appIconAlt: "DiskOUTアプリアイコン",
      heroTitle: "何もしなくて大丈夫。<br>ディスクは安全に取り出されます。",
      tagline: "Macは完璧です。あの通知さえなければ。DiskOUTが無料で解決します。",
      notification: '<s>「ディスクの不正な取り出し」</s><br><small>もう表示されません。</small>',
      downloadMac: "Mac用をダウンロード →",
      viewGitHub: "GitHubで見る",
      requirements: "無料 · 約4 MB · macOS 13+ · Apple Silicon · Apple公証済み",
      howTitle: "仕組み",
      step1Title: '<span class="n">1.</span> ふたを閉じると、すべてを安全に取り出します。',
      step1Body: "閉じる → 取り出し。開く → 再マウント。スリープ → 取り出し。復帰 → 再マウント。操作は不要です。",
      step2Title: '<span class="n">2.</span> 10台のドライブも一度に取り出します。',
      step2Body: "ショートカット1つ、またはメニューバーアイコンの右クリック1回ですべて取り出せます。",
      step3Title: '<span class="n">3.</span> 接続台数をひと目で確認できます。',
      step3Body: "メニューバーに接続中の外付けドライブ数をリアルタイムで表示します。",
      demoTitle: "動作を見る",
      demoPlaceholder: "▶︎ デモ準備中 — ふたを閉じる → 取り出し → 警告なし → 開く → 再マウント",
      safeTitle: "安全を優先した設計",
      feature1Title: "Time Machineを自動保護",
      feature1Body: "バックアップディスクは自動取り出しから除外され、バックアップを中断しません。",
      feature2Title: "不正な取り出しの警告なし",
      feature2Body: "スリープ前に正常なアンマウントを行うため、macOSは警告を表示しません。",
      feature3Title: "ディスクごとに除外",
      feature3Body: "ボリュームUUID基準なので、ケーブルやポートを変えても設定が維持されます。",
      feature4Title: "広告・追跡なし",
      feature4Body: "アップデート確認以外の外部通信はありません。",
      feature5Title: "Developer ID・公証済み",
      feature5Body: "Gatekeeperを通過し、「開発元を確認できない」警告は表示されません。",
      feature6Title: "読み書きアクティビティ表示",
      feature6Body: "ドライブの使用中は青い点でお知らせします。",
      compareTitle: "DiskOUTとほかの選択肢",
      macBuiltIn: "macOS標準機能",
      compareSleep: "スリープ時に自動取り出し",
      compareWake: "復帰時に自動再マウント",
      compareAll: "すべてを一括取り出し",
      compareTM: "Time Machineを保護",
      price: "価格",
      free: "無料",
      compareNote: "無料のJettison代替をお探しなら、DiskOUTが主要機能を無償で提供します。",
      faqTitle: "よくある質問",
      faq1Q: 'Macの「ディスクの不正な取り出し」警告を止めるには？',
      faq1A: "DiskOUTをインストールしてください。Macのスリープ前に外付けドライブを正常に取り出し、復帰時に再マウントするため、警告が表示されません。",
      faq2Q: "本当に無料ですか？",
      faq2A: "はい。アカウントやサインインなしでGitHub Releasesから無料でダウンロードできます。",
      faq3Q: "データを失う可能性はありますか？",
      faq3A: "DiskOUTはmacOS標準の取り出し経路で正常なアンマウントを先に試します。安全に取り出せないディスクはそのままにして通知だけを表示します。",
      faq4Q: "Intel Macでも動作しますか？",
      faq4A: "現在の配布ビルドはApple Silicon（M1/M2/M3/M4）専用で、macOS 13 Ventura以降が必要です。",
      faq5Q: "Homebrewでインストールするには？",
      downloadFree: "DiskOUTを無料でダウンロード",
      feedback: "フィードバック"
    },
    "zh-Hans": {
      pageTitle: 'DiskOUT — 睡眠前自动推出，避免“磁盘未正确推出”警告',
      pageDescription: 'Mac睡眠前自动推出所有外置驱动器，唤醒时重新挂载。免费、已通过Apple公证、支持4种语言。',
      language: "语言",
      appIconAlt: "DiskOUT App图标",
      heroTitle: "无需任何操作。<br>磁盘会被安全推出。",
      tagline: "Mac几乎完美，只差解决那一个提醒。DiskOUT免费替你处理。",
      notification: '<s>“磁盘未正确推出”</s><br><small>以后不会再看到它。</small>',
      downloadMac: "下载Mac版 →",
      viewGitHub: "在GitHub上查看",
      requirements: "免费 · 约4 MB · macOS 13+ · Apple Silicon · 已通过Apple公证",
      howTitle: "工作方式",
      step1Title: '<span class="n">1.</span> 合上上盖，安全推出所有驱动器。',
      step1Body: "合盖 → 推出。开盖 → 重新挂载。睡眠 → 推出。唤醒 → 重新挂载。无需手动操作。",
      step2Title: '<span class="n">2.</span> 10个驱动器也能一次推出。',
      step2Body: "一个快捷键或一次右键点击菜单栏图标，即可全部推出。",
      step3Title: '<span class="n">3.</span> 一眼查看驱动器数量。',
      step3Body: "菜单栏会实时显示已连接的外置驱动器数量。",
      demoTitle: "查看实际效果",
      demoPlaceholder: "▶︎ 演示准备中 — 合盖 → 推出驱动器 → 无警告 → 开盖 → 重新挂载",
      safeTitle: "以安全为核心的设计",
      feature1Title: "自动保护Time Machine",
      feature1Body: "备份磁盘会从自动推出中排除，不会中断备份。",
      feature2Title: "不再出现未正确推出警告",
      feature2Body: "睡眠前先正常卸载，因此macOS不会发出警告。",
      feature3Title: "按磁盘单独排除",
      feature3Body: "基于宗卷UUID，换线缆或端口后设置仍然有效。",
      feature4Title: "无广告、无跟踪",
      feature4Body: "除检查更新外，不会与外部通信。",
      feature5Title: "Developer ID及Apple公证",
      feature5Body: "通过Gatekeeper检查，不会出现“无法验证开发者”提示。",
      feature6Title: "读写活动指示",
      feature6Body: "驱动器忙碌时会显示蓝点提醒。",
      compareTitle: "DiskOUT与其他方案",
      macBuiltIn: "macOS内置功能",
      compareSleep: "睡眠时自动推出",
      compareWake: "唤醒时自动重新挂载",
      compareAll: "一次推出全部",
      compareTM: "保护Time Machine",
      price: "价格",
      free: "免费",
      compareNote: "如果你在寻找免费的Jettison替代方案，DiskOUT免费提供全部核心功能。",
      faqTitle: "常见问题",
      faq1Q: '如何停止Mac上的“磁盘未正确推出”警告？',
      faq1A: "安装DiskOUT。Mac睡眠前会正常推出所有外置驱动器，唤醒时重新挂载，因此不会触发警告。",
      faq2Q: "真的免费吗？",
      faq2A: "是的。无需帐户或登录，可从GitHub Releases免费下载。",
      faq3Q: "会丢失数据吗？",
      faq3A: "DiskOUT使用macOS标准推出流程，先尝试正常卸载。无法安全推出的磁盘会保持原状，并只发送通知。",
      faq4Q: "支持Intel Mac吗？",
      faq4A: "当前发布版本仅支持Apple Silicon（M1/M2/M3/M4），需要macOS 13 Ventura或更高版本。",
      faq5Q: "如何通过Homebrew安装？",
      downloadFree: "免费下载DiskOUT",
      feedback: "反馈"
    }
  };

  const textNodes = [...document.querySelectorAll("[data-i18n]")];
  const htmlNodes = [...document.querySelectorAll("[data-i18n-html]")];
  const altNodes = [...document.querySelectorAll("[data-i18n-alt]")];
  const base = new Map();
  for (const element of textNodes) base.set(element, element.textContent);
  for (const element of htmlNodes) base.set(element, element.innerHTML);
  for (const element of altNodes) base.set(element, element.getAttribute("alt"));
  const baseTitle = document.title;
  const description = document.querySelector('meta[name="description"]');
  const baseDescription = description?.content ?? "";

  function supportedLanguage(identifier) {
    const value = String(identifier || "").toLowerCase();
    if (value === "ko" || value.startsWith("ko-")) return "ko";
    if (value === "ja" || value.startsWith("ja-")) return "ja";
    if (value === "zh" || value === "zh-hans" || value.startsWith("zh-hans-") || value === "zh-cn" || value.startsWith("zh-cn-") || value === "zh-sg" || value.startsWith("zh-sg-")) return "zh-Hans";
    if (value === "en" || value.startsWith("en-")) return "en";
    return null;
  }

  function preferredLanguage() {
    try {
      const saved = localStorage.getItem("diskout.language");
      if (["en", "ko", "ja", "zh-Hans"].includes(saved)) return saved;
    } catch (_) {}
    const browserLanguages = navigator.languages?.length ? navigator.languages : [navigator.language];
    for (const identifier of browserLanguages) {
      const match = supportedLanguage(identifier);
      if (match) return match;
    }
    return "en";
  }

  function applyLanguage(language) {
    const dictionary = translations[language] || {};
    for (const element of textNodes) {
      const key = element.dataset.i18n;
      element.textContent = dictionary[key] ?? base.get(element);
    }
    for (const element of htmlNodes) {
      const key = element.dataset.i18nHtml;
      element.innerHTML = dictionary[key] ?? base.get(element);
    }
    for (const element of altNodes) {
      const key = element.dataset.i18nAlt;
      element.setAttribute("alt", dictionary[key] ?? base.get(element));
    }
    document.documentElement.lang = language;
    document.title = dictionary.pageTitle ?? baseTitle;
    if (description) description.content = dictionary.pageDescription ?? baseDescription;
    const selector = document.getElementById("language-select");
    selector.value = language;
    selector.setAttribute("aria-label", dictionary.language ?? "Language");
  }

  const selector = document.getElementById("language-select");
  selector.addEventListener("change", () => {
    const language = selector.value;
    try { localStorage.setItem("diskout.language", language); } catch (_) {}
    applyLanguage(language);
  });
  applyLanguage(preferredLanguage());
})();
