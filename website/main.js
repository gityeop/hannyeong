class HeroTitle {
  constructor(root) {
    this.root = root;
    this.desktop = window.matchMedia('(min-width: 761px)');
    this.updateRange = () => { this.range = this.desktop.matches ? 64 : 160; };
    this.updateRange();
    this.shown = 0;
  }
  componentDidMount() {
    this.desktop.addEventListener('change', this.updateRange);
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      this.shown = 1;
      this.render();
      return;
    }
    const loop = () => {
      const target = Math.max(0, Math.min(1, window.scrollY / this.range));
      this.shown += (target - this.shown) * 0.14;
      if (Math.abs(target - this.shown) < 0.0005) this.shown = target;
      this.render();
      this.frame = requestAnimationFrame(loop);
    };
    this.frame = requestAnimationFrame(loop);
  }
  componentWillUnmount() {
    cancelAnimationFrame(this.frame);
    this.desktop.removeEventListener('change', this.updateRange);
  }
  render() {
    const p = this.shown * this.shown * (3 - 2 * this.shown);
    const fade = Math.min(1, p * 1.4);
    const opacity = 1 - fade * fade * (3 - 2 * fade);
    const flight = Math.sin(Math.PI * p);
    const angles = [0, -26, 18, 0, -18, 24, -15, 0, 22, 0];
    this.root.querySelectorAll('[data-char]').forEach((span, i) => {
      if (i === 0 || i === 9) {
        span.style.transform = `translateY(${-flight * 0.06}em) rotate(${flight * (i === 0 ? -10 : 10)}deg)`;
        return;
      }
      span.style.maxWidth = ((1 - p) * (span.textContent === ' ' ? 0.3 : 1.1)) + 'em';
      span.style.opacity = opacity;
      span.style.filter = `blur(${(1 - opacity) * 1.5}px)`;
      span.style.transform = `translate(${flight * ((i % 3) - 1) * 0.32}em, ${-flight * (0.5 + (i % 3) * 0.15)}em) rotate(${flight * angles[i]}deg)`;
    });
    const row = this.root.querySelector('[data-hero-row]');
    const chars = this.root.querySelectorAll('[data-char]');
    const firstWidth = chars[0].offsetWidth;
    const finish = Math.max(0, Math.min(1, (p - 0.82) / 0.18));
    row.style.setProperty('--merge-finish', finish);
    row.style.setProperty('--merged-width', `${firstWidth + chars[9].offsetWidth}px`);
    row.classList.toggle('is-merged', this.shown >= 0.98);
    this.root.querySelector('[data-title-second]').style.transform = `translate(${p * firstWidth}px, ${-p * 1.08}em)`;
    // The title is centred, so shift it left by half of the first glyph as the second line slides under it.
    row.style.transform = `translateX(${-p * firstWidth / 2}px) scale(${1 - p * 0.08 + Math.sin(Math.PI * finish) * 0.018})`;
    row.style.height = `${2.16 - p * 1.08}em`;
  }
}

class TypingDemo {
  // Every frame derives the whole demo from elapsed time, so keys ease in, committed words come into
  // focus and the caret blinks without relying on CSS keyframe animations.
  constructor(root, props = {}) {
    this.root = root;
    this.props = props;
    this.setState = (values) => { Object.assign(this.state, values); this.render(); };
    this.forceUpdate = () => this.render();
    const examples = [
      [['dhsmf', '오늘'], ['meeting', 'meeting'], ['auc', '몇'], ['tldi?', '시야?']],
      [['PR', 'PR'], ['dhffuTdj', '올렸어'], ['review', 'review'], ['qnxkrgo', '부탁해']],
      [['deploy', 'deploy'], ['Rmxskaus', '끝나면'], ['qkfh', '바로'], ['dkffuwnj', '알려줘']]
    ];
    // Per example: when each key goes down, when each word is committed with Space, and when it ends.
    this.timelines = examples.map((words) => {
      let t = 0;
      const plan = words.map(([keys, text], wi) => {
        const presses = [];
        for (let i = 0; i < keys.length; i++) {
          if (i > 0 || wi > 0) t += (i === 0 ? 150 : 92) + ((keys.charCodeAt(i) * 37) % 70);
          presses.push(t);
        }
        t += 260;
        const commit = t;
        t += 190;
        return { keys, text, presses, commit };
      });
      return { plan, length: plan[plan.length - 1].commit + 2600 };
    });
    this.total = this.timelines.reduce((sum, x) => sum + x.length, 0);
    this.state = { now: 0 };
  }
  componentDidMount() {
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduce) { this.still = true; this.forceUpdate(); return; }
    const started = performance.now();
    const loop = (now) => { this.setState({ now: now - started }); this.frame = requestAnimationFrame(loop); };
    this.frame = requestAnimationFrame(loop);
  }
  componentWillUnmount() { if (this.frame) cancelAnimationFrame(this.frame); }
  compose(keys) {
    const CHO = 'ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ', JUNG = 'ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ';
    const JONG = ['', 'ㄱ', 'ㄲ', 'ㄳ', 'ㄴ', 'ㄵ', 'ㄶ', 'ㄷ', 'ㄹ', 'ㄺ', 'ㄻ', 'ㄼ', 'ㄽ', 'ㄾ', 'ㄿ', 'ㅀ', 'ㅁ', 'ㅂ', 'ㅄ', 'ㅅ', 'ㅆ', 'ㅇ', 'ㅈ', 'ㅊ', 'ㅋ', 'ㅌ', 'ㅍ', 'ㅎ'];
    const MAP = { r:'ㄱ', R:'ㄲ', s:'ㄴ', e:'ㄷ', E:'ㄸ', f:'ㄹ', a:'ㅁ', q:'ㅂ', Q:'ㅃ', t:'ㅅ', T:'ㅆ', d:'ㅇ', w:'ㅈ', W:'ㅉ', c:'ㅊ', z:'ㅋ', x:'ㅌ', v:'ㅍ', g:'ㅎ',
      k:'ㅏ', o:'ㅐ', i:'ㅑ', O:'ㅒ', j:'ㅓ', p:'ㅔ', u:'ㅕ', P:'ㅖ', h:'ㅗ', y:'ㅛ', n:'ㅜ', b:'ㅠ', m:'ㅡ', l:'ㅣ' };
    const VV = { 'ㅗㅏ':'ㅘ', 'ㅗㅐ':'ㅙ', 'ㅗㅣ':'ㅚ', 'ㅜㅓ':'ㅝ', 'ㅜㅔ':'ㅞ', 'ㅜㅣ':'ㅟ', 'ㅡㅣ':'ㅢ' };
    const CC = { 'ㄱㅅ':'ㄳ', 'ㄴㅈ':'ㄵ', 'ㄴㅎ':'ㄶ', 'ㄹㄱ':'ㄺ', 'ㄹㅁ':'ㄻ', 'ㄹㅂ':'ㄼ', 'ㄹㅅ':'ㄽ', 'ㄹㅌ':'ㄾ', 'ㄹㅍ':'ㄿ', 'ㄹㅎ':'ㅀ', 'ㅂㅅ':'ㅄ' };
    const SPLIT = {}; for (const k in CC) SPLIT[CC[k]] = [k[0], k[1]];
    let out = '', cho = '', jung = '', jong = '';
    const flush = () => {
      if (cho && jung) out += String.fromCharCode(0xAC00 + (CHO.indexOf(cho) * 21 + JUNG.indexOf(jung)) * 28 + JONG.indexOf(jong));
      else out += cho + jung + jong;
      cho = jung = jong = '';
    };
    for (const ch of keys) {
      const j = MAP[ch] || MAP[ch.toLowerCase()];
      if (!j) { flush(); out += ch; continue; }
      if (CHO.includes(j)) {
        if (cho && jung && !jong && JONG.includes(j)) jong = j;
        else if (jong && CC[jong + j]) jong = CC[jong + j];
        else { flush(); cho = j; }
      } else {
        if (jong) {
          const [keep, move] = SPLIT[jong] || ['', jong];
          jong = keep; flush(); cho = move; jung = j;
        } else if (cho && !jung) jung = j;
        else if (jung && VV[jung + j]) jung = VV[jung + j];
        else { flush(); jung = j; }
      }
    }
    flush();
    return out;
  }

  renderVals() {
    const ease = (x) => 1 - Math.pow(1 - Math.max(0, Math.min(1, x)), 3);
    let clock = this.state.now % this.total, timeline = this.timelines[0];
    for (const candidate of this.timelines) {
      if (clock < candidate.length) { timeline = candidate; break; }
      clock -= candidate.length;
    }
    const plan = timeline.plan;
    if (this.still) clock = plan[plan.length - 1].commit + 1000;
    const cap = 'display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box; min-width: 28px; height: 30px; padding: 0 8px; font-family: \'JetBrains Mono\', ui-monospace, Menlo, monospace; font-size: 13px; color: var(--ink); border: 1px solid var(--key-border); border-radius: 7px; background: var(--key-bg); ';
    const keyStyle = (age, extra) => {
      const p = ease(age / 180);
      const down = age < 90;
      return cap + (extra || '') + 'opacity: ' + p.toFixed(3) + '; border-bottom-width: ' + (down ? 1 : 2) + 'px; transform: translateY(' + ((1 - p) * 5 + (down ? 1.5 : 0)).toFixed(2) + 'px) scale(' + (0.9 + 0.1 * p).toFixed(3) + ')';
    };
    // The word on the keys row: the latest started word, kept (with its space key) until the next one starts.
    let current = -1;
    plan.forEach((word, i) => { if (word.presses[0] <= clock) current = i; });
    const active = current >= 0 ? plan[current] : null;
    const keys = [];
    if (active) {
      active.presses.forEach((at, i) => { if (at <= clock) keys.push({ label: active.keys[i], style: keyStyle(clock - at) }); });
      if (active.commit <= clock) keys.push({ label: 'space', style: keyStyle(clock - active.commit, 'min-width: 70px; color: var(--muted); font-size: 11px; ') });
    }
    const words = plan.filter((word) => word.commit <= clock).map((word) => {
      const p = ease((clock - word.commit) / 380);
      return { text: word.text, style: 'display: inline-block; margin-right: .26em; opacity: ' + p.toFixed(3) + '; filter: blur(' + ((1 - p) * 3).toFixed(2) + 'px); transform: translateY(' + ((1 - p) * 6).toFixed(2) + 'px)' };
    });
    const typing = active && active.commit > clock ? active.keys.slice(0, active.presses.filter((at) => at <= clock).length) : '';
    let lastKey = -1e9;
    plan.forEach((word) => word.presses.concat(word.commit).forEach((at) => { if (at <= clock && at > lastKey) lastKey = at; }));
    const caretOn = this.still || clock - lastKey < 500 || Math.floor(this.state.now / 530) % 2 === 0;
    return {
      keys,
      words,
      raw: this.compose(typing),
      rawKeys: typing,
      caretStyle: 'display: inline-block; width: 2px; height: .95em; background: var(--red); vertical-align: -.1em; margin-left: 3px; transition: opacity .12s ease; opacity: ' + (caretOn ? 1 : 0)
    };
  }
  render() {
    const values = this.renderVals();
    for (const name of ['keys', 'words']) {
      const container = this.root.querySelector(`[data-${name}]`);
      while (container.children.length > values[name].length) container.lastElementChild.remove();
      values[name].forEach((item, i) => {
        const span = container.children[i] || container.appendChild(document.createElement('span'));
        span.textContent = item.label ?? item.text;
        span.style.cssText = item.style;
      });
    }
    this.root.querySelector('[data-raw]').textContent = values.raw;
    this.root.querySelector('[data-caret]').style.cssText = values.caretStyle;
  }

}

class CompositionPreviewDemo extends TypingDemo {
  render() {
    const values = this.renderVals();
    const committed = values.words.map(word => word.text).join(' ');
    this.root.querySelectorAll('[data-preview-output]').forEach(output => {
      output.querySelector('[data-preview-committed]').textContent = committed + (committed && values.rawKeys ? ' ' : '');
      output.querySelector('[data-preview-composing]').textContent = output.dataset.previewOutput === 'ko' ? values.raw : values.rawKeys;
      output.querySelector('[data-preview-caret]').style.cssText = values.caretStyle;
    });
  }
}

class Keycap {
  // Port of the settings window's CommandShortcutDemo: an 8 pt press with a 0.08 s ease-out each way,
  // a 0.12 s hold, 0.1 s between taps, repeating every 2.5 s.
  constructor(root, props = {}) {
    this.root = root;
    this.props = props;
    this.setState = (values) => { Object.assign(this.state, values); this.render(); };
    this.forceUpdate = () => this.render();
    this.state = { depression: 0, shown: false };
  }
  componentDidMount() {
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduce) { this.setState({ shown: true }); return; }
    const ease = (x) => 1 - (1 - x) * (1 - x);
    const started = performance.now();
    const loop = (now) => {
      const taps = Number(this.props.taps) === 2 ? 2 : 1;
      const elapsed = now - started - 450;
      let depression = 0, shown = false;
      if (elapsed >= 0) {
        const t = elapsed % 2500;
        for (let k = 0; k < taps; k++) {
          const s = t - k * 380;
          if (s >= 0 && s < 80) depression = 8 * ease(s / 80);
          else if (s >= 80 && s < 200) depression = 8;
          else if (s >= 200 && s < 280) depression = 8 * (1 - ease((s - 200) / 80));
        }
        shown = t >= taps * 380 - 100 && t < 2150;
      }
      depression = Math.round(depression * 10) / 10;
      if (depression !== this.state.depression || shown !== this.state.shown) this.setState({ depression, shown });
      this.frame = requestAnimationFrame(loop);
    };
    this.frame = requestAnimationFrame(loop);
  }
  componentWillUnmount() { if (this.frame) cancelAnimationFrame(this.frame); }
  renderVals() {
    const double = Number(this.props.taps) === 2;
    const d = this.state.depression;
    const top = [1, 0.1, -0.18, 0.78, 34, 17 + d];
    const base = [1, 0.1, -0.18, 0.78, 28, 35];
    const at = (m, x, y) => (m[0] * x + m[2] * y + m[4]).toFixed(2) + ' ' + (m[1] * x + m[3] * y + m[5]).toFixed(2);
    const r = 22, c = r * 0.5522847498;
    const u = (x, y) => at(top, x, y), l = (x, y) => at(base, x, y);
    const wall = 'M' + u(0, r) + ' L' + u(0, 82 - r)
      + ' C' + u(0, 82 - r + c) + ' ' + u(r - c, 82) + ' ' + u(r, 82)
      + ' L' + u(104 - r, 82)
      + ' C' + u(104 - r + c, 82) + ' ' + u(104, 82 - r + c) + ' ' + u(104, 82 - r)
      + ' L' + u(104, r) + ' L' + l(114, r) + ' L' + l(114, 88 - r)
      + ' C' + l(114, 88 - r + c) + ' ' + l(114 - r + c, 88) + ' ' + l(114 - r, 88)
      + ' L' + l(r, 88)
      + ' C' + l(r - c, 88) + ' ' + l(0, 88 - r + c) + ' ' + l(0, 88 - r)
      + ' L' + l(0, r) + ' Z';
    const fade = 'grid-area: 1 / 1; transition: opacity .45s cubic-bezier(.2,.8,.2,1), transform .45s cubic-bezier(.2,.8,.2,1), filter .45s ease; ';
    const on = 'opacity: 1; transform: none; filter: none';
    const off = 'opacity: 0; transform: translateY(6px) scale(.98); filter: blur(3px)';
    const word = 'font-size: 26px; font-weight: 700; letter-spacing: -0.02em; line-height: 1.2; white-space: nowrap; ';
    const shown = this.state.shown;
    return {
      single: !double,
      double,
      gid: double ? 'hn-k2' : 'hn-k1',
      title: double ? '교정창 열기' : '한·영 반전',
      instruction: double ? '오른쪽 Command 빠르게 두 번' : '오른쪽 Command 한 번',
      topTransform: 'matrix(' + top.join(' ') + ')',
      wall,
      shadowY: (5 - d / 4).toFixed(2),
      shadowBlur: ((6 - d / 4) / 2).toFixed(2),
      beforeStyle: fade + word + (shown ? off : on),
      afterStyle: fade + word + (shown ? on : off),
      waitStyle: fade + 'font-size: 14px; color: var(--subtle); ' + (shown ? off : on),
      popupStyle: fade + 'display: flex; flex-direction: column; gap: 2px; background: var(--popup-bg); border: 1px solid var(--line-strong); border-radius: 12px; padding: 5px; box-shadow: 0 10px 24px -12px rgba(0,0,0,.35); min-width: 150px; ' + (shown ? on : off)
    };
  }
  render() {
    const values = this.renderVals();
    this.root.querySelector('[data-wall]').setAttribute('d', values.wall);
    this.root.querySelector('[data-key-top]').setAttribute('transform', values.topTransform);
    const shadow = this.root.querySelector('[data-key-shadow]');
    shadow.setAttribute('dy', values.shadowY);
    shadow.setAttribute('stdDeviation', values.shadowBlur);
    for (const field of ['beforeStyle', 'afterStyle', 'waitStyle', 'popupStyle']) {
      const layer = this.root.querySelector(`[data-${field.toLowerCase()}]`);
      if (layer) layer.style.cssText = values[field];
    }
  }

}

const THEME_KEY = 'hannyeong.theme';
const themeToggle = document.querySelector('[data-theme-toggle]');
const systemDark = window.matchMedia('(prefers-color-scheme: dark)');
const currentTheme = () => document.documentElement.dataset.theme || (systemDark.matches ? 'dark' : 'light');
const labelThemeToggle = () => {
  themeToggle.setAttribute('aria-label', currentTheme() === 'dark' ? '밝은 화면으로 바꾸기' : '어두운 화면으로 바꾸기');
};
themeToggle.addEventListener('click', () => {
  const next = currentTheme() === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = next;
  try { localStorage.setItem(THEME_KEY, next); } catch (error) { /* 저장할 수 없으면 이번 방문에만 적용합니다. */ }
  labelThemeToggle();
});
systemDark.addEventListener('change', labelThemeToggle);
labelThemeToggle();

// 원고지 칸 라벨: 섹션 라벨을 한 글자씩 칸에 넣고, 화면에 들어오면 타이핑하듯 채웁니다.
for (const label of document.querySelectorAll('.eyebrow')) {
  const text = label.textContent.trim();
  const readable = document.createElement('span');
  readable.className = 'sr-only';
  readable.textContent = text;
  label.className = 'cells';
  label.replaceChildren(readable, ...[...text].map((ch, i) => {
    const cell = document.createElement('span');
    cell.textContent = ch === ' ' ? '' : ch;
    cell.style.setProperty('--i', i);
    cell.setAttribute('aria-hidden', 'true');
    return cell;
  }));
  const caret = document.createElement('span');
  caret.className = 'cells-caret';
  caret.style.setProperty('--i', text.length);
  caret.setAttribute('aria-hidden', 'true');
  label.append(caret);
}
if (!window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
  document.documentElement.classList.add('motion');
  const revealObserver = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add('is-in');
      revealObserver.unobserve(entry.target);
    }
  }, { threshold: 0.2 });
  const targets = new Set();
  for (const mark of document.querySelectorAll('main .cells, main .pen')) targets.add(mark.closest('section') || mark.parentElement);
  for (const target of targets) {
    target.classList.add('reveal');
    revealObserver.observe(target);
  }
}

const navLinks = Array.from(document.querySelectorAll('.nav-links a[href^="#"]'));
const navObserver = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    for (const link of navLinks) {
      if (link.getAttribute('href') === `#${entry.target.id}`) link.setAttribute('aria-current', 'true');
      else link.removeAttribute('aria-current');
    }
  }
}, { rootMargin: '-45% 0px -50% 0px' });
for (const link of navLinks) {
  const target = document.querySelector(link.getAttribute('href'));
  if (target) navObserver.observe(target);
}

const introVideo = document.querySelector('[data-scroll-play]');
const introVideoObserver = new IntersectionObserver(([entry]) => {
  if (entry.isIntersecting && entry.intersectionRatio >= 0.25) {
    introVideo.play().catch(error => console.error('소개 영상 자동 재생 실패:', error));
  } else {
    introVideo.pause();
  }
}, { threshold: [0, 0.25] });
introVideoObserver.observe(introVideo);

const demos = [
  new HeroTitle(document.querySelector('#hn-hero-pin')),
  new TypingDemo(document.querySelector('[data-typing]')),
  new CompositionPreviewDemo(document.querySelector('[data-composition-preview]')),
  ...Array.from(document.querySelectorAll('[data-keycap]'), root => new Keycap(root, { taps: root.dataset.keycap }))
];
for (const demo of demos) {
  demo.render();
  demo.componentDidMount();
}
const motionPreference = window.matchMedia('(prefers-reduced-motion: reduce)');
motionPreference.addEventListener('change', () => {
  for (const demo of demos) demo.componentWillUnmount();
  window.location.reload();
});
