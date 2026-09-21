/**
 * MediaDeck 展开动画 demo
 * 约定：
 * - 前景卡 order=0 位姿不动，z 最高
 * - 后卡按 order 1..n-1 铺开
 * - 运动中抬高 zIndex，落位后统一层
 */

const TITLES = [
  ['视频', '转换 · 压缩 · 裁剪'],
  ['图片', '格式 · 尺寸 · 压缩'],
  ['GIF', '优化 · 帧率 · 循环'],
  ['音频', '转换 · 裁剪 · 响度'],
  ['字幕', '转换 · 偏移'],
  ['动态照片', '静态图 · 短视频 · GIF']
];

const PRESETS = {
  hold: {
    ease: 'cubic-bezier(.22,1,.36,1)',
    move: 480,
    stagger: 120,
    dealZ: 98,
    settledZBase: 94,
    peek: 8,
    cardGap: 10
  },
  cascade: {
    ease: 'cubic-bezier(.16,1,.3,1)',
    move: 620,
    stagger: 90,
    dealZ: 98,
    settledZBase: 94,
    peek: 6,
    cardGap: 8
  },
  peel: {
    ease: 'cubic-bezier(.22,1,.36,1)',
    move: 420,
    stagger: 130,
    dealZ: 98,
    settledZBase: 94,
    peek: 8,
    cardGap: 10,
    twoStage: true
  },
  springs: {
    ease: 'cubic-bezier(.34,1.42,.64,1)',
    move: 560,
    stagger: 150,
    dealZ: 98,
    settledZBase: 94,
    peek: 8,
    cardGap: 10
  }
};

function stageHeight(stage) {
  return stage.clientHeight || 320;
}

function stackedY(order, preset) {
  return order * preset.peek;
}

function dealtY(order, preset) {
  // order 0 前景：与叠放顶对齐（不动）
  // order >=1：往下铺
  return order * (78 + preset.cardGap);
}

function createCards(stage) {
  stage.innerHTML = '';
  const cards = TITLES.map((meta, i) => {
    const el = document.createElement('div');
    el.className = 'pcard';
    el.dataset.order = String(i);
    el.innerHTML = `
      <div class="art" aria-hidden="true"></div>
      <div class="tag">${meta[0]}</div>
      <div class="sub">${meta[1]}</div>
    `;
    stage.appendChild(el);
    return el;
  });
  return cards;
}

function applyPose(el, { y, s, z, opacity }) {
  el.style.setProperty('--y', `${y}px`);
  el.style.setProperty('--s', String(s));
  el.style.setProperty('--z', String(z));
  el.style.opacity = String(opacity);
}

function resetStack(cards, preset) {
  cards.forEach((el, order) => {
    el.classList.remove('is-dealing', 'is-lift');
    el.style.transitionDuration = '0ms';
    const isFront = order === 0;
    applyPose(el, {
      y: stackedY(order, preset),
      s: isFront ? 1 : Math.max(0.92, 1 - order * 0.02),
      z: isFront ? 100 : 90 - order,
      opacity: order > 4 ? 0 : 1
    });
    el.classList.toggle('is-front', isFront);
  });
  // 下一帧恢复过渡
  requestAnimationFrame(() => {
    cards.forEach((el) => {
      el.style.setProperty('--ease', preset.ease);
      el.style.transitionDuration = `${preset.move}ms`;
    });
  });
}

function collapse(deck, preset) {
  deck.timers.forEach((id) => clearTimeout(id));
  deck.timers = [];
  deck.expanded = false;

  deck.cards.forEach((el, order) => {
    el.classList.remove('is-dealing', 'is-lift');
    const isFront = order === 0;
    applyPose(el, {
      y: stackedY(order, preset),
      s: isFront ? 1 : Math.max(0.92, 1 - order * 0.02),
      z: isFront ? 100 : 90 - order,
      opacity: order > 4 ? 0 : 1
    });
  });
}

function expand(deck, preset) {
  deck.timers.forEach((id) => clearTimeout(id));
  deck.timers = [];
  deck.expanded = true;

  const n = deck.cards.length;
  const maxOrder = n - 1;
  const h = stageHeight(deck.stage);
  const totalH = dealtY(maxOrder, preset) + 78;
  const offsetY = Math.max(0, (h - totalH) / 2 - 8);

  // 前景卡立刻定在最终顶位（竖屏同宽单列时 y 叠放≈0，展开后仍在顶）
  applyPose(deck.cards[0], {
    y: stackedY(0, preset) + offsetY * 0,
    s: 1,
    z: 100,
    opacity: 1
  });
  deck.cards[0].classList.add('is-front');

  for (let step = 1; step <= maxOrder; step++) {
    const id = setTimeout(() => {
      if (!deck.expanded) {
        return;
      }
      const el = deck.cards[step];
      el.classList.add('is-dealing');
      if (preset.twoStage) {
        el.classList.add('is-lift');
        applyPose(el, {
          y: stackedY(step, preset) - 6,
          s: 1.02,
          z: preset.dealZ,
          opacity: 1
        });
        const id2 = setTimeout(() => {
          el.classList.remove('is-lift');
          applyPose(el, {
            y: dealtY(step, preset) + offsetY,
            s: 1,
            z: preset.settledZBase + step * 0.01,
            opacity: 1
          });
          const id3 = setTimeout(() => {
            el.classList.remove('is-dealing');
          }, preset.move);
          deck.timers.push(id3);
        }, 120);
        deck.timers.push(id2);
      } else {
        applyPose(el, {
          y: dealtY(step, preset) + offsetY,
          s: 1,
          // 运动中最高（仅低于前景），落位后略抬，避免「后张永远更低」
          z: preset.dealZ,
          opacity: 1
        });
        const id2 = setTimeout(() => {
          el.style.setProperty('--z', String(preset.settledZBase + step * 0.01));
          el.classList.remove('is-dealing');
        }, preset.move);
        deck.timers.push(id2);
      }
    }, (step - 1) * preset.stagger);
    deck.timers.push(id);
  }

  // cascade：额外把已在飞的卡 z 维持在前景下一层，避免钻入
  if (!preset.twoStage) {
    deck.cards.forEach((el, order) => {
      if (order > 0 && order < 1) {
        /* noop */
      }
    });
  }
}

function initDemo(key) {
  const stage = document.getElementById(`stage-${key}`);
  const btn = document.querySelector(`.demo-card[data-demo="${key}"] .toggle-btn`);
  if (!stage || !btn) {
    return;
  }
  const preset = PRESETS[key];
  const cards = createCards(stage);
  const deck = { stage, cards, preset, expanded: false, timers: [] };
  resetStack(cards, preset);
  btn.addEventListener('click', () => {
    if (deck.expanded) {
      collapse(deck, preset);
    } else {
      expand(deck, preset);
    }
  });
}

['hold', 'cascade', 'peel', 'springs'].forEach((key) => initDemo(key));
