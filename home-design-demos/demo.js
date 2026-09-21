(function () {
  function fitOne(viewport) {
    var scaleEl = viewport.querySelector('.device-scale');
    if (!scaleEl) return;
    var designW = parseFloat(scaleEl.getAttribute('data-design-w')) || 1280;
    var avail = viewport.clientWidth || (viewport.parentElement && viewport.parentElement.clientWidth) || designW;
    var scale = Math.min(1, avail / designW);
    if (!(scale > 0) || !isFinite(scale)) scale = 1;
    scaleEl.style.transformOrigin = 'top left';
    scaleEl.style.transform = 'none';
    var naturalH = Math.max(scaleEl.scrollHeight, scaleEl.offsetHeight) || (designW === 390 ? 1400 : 900);
    scaleEl.style.transform = 'scale(' + scale + ')';
    viewport.style.height = Math.ceil(naturalH * scale + 2) + 'px';
    var key = viewport.getAttribute('data-fit');
    var fitLabel = document.querySelector('[data-fit-label="' + key + '"]');
    if (fitLabel) {
      fitLabel.textContent = '缩放 ' + Math.round(scale * 100) + '% · 内容高约 ' + naturalH + 'px';
    }
  }

  function fitAll() {
    Array.prototype.forEach.call(document.querySelectorAll('.device-viewport'), function (vp) {
      var col = vp.closest('.frame-col');
      if (col && col.hasAttribute('hidden')) return;
      fitOne(vp);
    });
  }

  var modeTabs = Array.prototype.slice.call(document.querySelectorAll('.mode-tab'));
  var cols = Array.prototype.slice.call(document.querySelectorAll('[data-show]'));

  function activateMode(mode) {
    cols.forEach(function (col) {
      var show = col.getAttribute('data-show') === mode;
      if (show) {
        col.removeAttribute('hidden');
        col.style.display = '';
      } else {
        col.setAttribute('hidden', '');
        col.style.display = 'none';
      }
    });
    modeTabs.forEach(function (t) {
      t.setAttribute('aria-selected', t.getAttribute('data-mode') === mode ? 'true' : 'false');
    });
    requestAnimationFrame(fitAll);
  }

  modeTabs.forEach(function (t) {
    t.addEventListener('click', function () {
      activateMode(t.getAttribute('data-mode') || 'pad');
    });
  });

  /* 拖入整屏变蓝 */
  function bindDropHot(el) {
    if (!el || el.__dropBound) return;
    el.__dropBound = true;
    var depth = 0;
    function hot(on) {
      el.classList.toggle('is-drop-hot', on);
    }
    el.addEventListener('dragenter', function (e) {
      e.preventDefault();
      depth++;
      hot(true);
    });
    el.addEventListener('dragover', function (e) {
      e.preventDefault();
      if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy';
      hot(true);
    });
    el.addEventListener('dragleave', function (e) {
      e.preventDefault();
      depth = Math.max(0, depth - 1);
      if (depth === 0) hot(false);
    });
    el.addEventListener('drop', function (e) {
      e.preventDefault();
      depth = 0;
      hot(false);
    });
  }

  function bindAllDropZones() {
    Array.prototype.forEach.call(document.querySelectorAll('.drop-zone-root'), bindDropHot);
  }

  function cloneCardsFromPad() {
    var padStage = document.querySelector('[data-deck="pad"] [data-deck-stage]');
    var phoneStage = document.querySelector('[data-deck="phone"] [data-deck-stage]');
    if (!padStage || !phoneStage) return;
    if (phoneStage.children.length) return;
    Array.prototype.forEach.call(padStage.querySelectorAll('.mcard'), function (card) {
      phoneStage.appendChild(card.cloneNode(true));
    });
  }

  function initDeck(root) {
    var stage = root.querySelector('[data-deck-stage]');
    var viewport = root.querySelector('[data-deck-viewport]');
    var nameEl = root.querySelector('[data-type-name]');
    var subEl = root.querySelector('[data-type-sub]');
    var nameHint = root.querySelector('[data-deck-name]');
    var prevBtn = root.querySelector('[data-deck-prev]');
    var nextBtn = root.querySelector('[data-deck-next]');
    var toggleBtn = root.querySelector('[data-deck-toggle]');
    var toggleText = root.querySelector('[data-toggle-text]');
    var dotsBox = root.querySelector('[data-deck-dots]');
    if (!stage || !viewport) return;

    var cards = Array.prototype.slice.call(stage.querySelectorAll('.mcard'));
    if (!cards.length) return;

    var index = 0;
    var expanded = false;
    var animating = false;
    var isPhone = root.getAttribute('data-deck') === 'phone';
    // 横屏卡片放大
    var cardW = isPhone ? 250 : 320;
    var cardH = isPhone ? 310 : 400;

    if (dotsBox) {
      dotsBox.innerHTML = '';
      cards.forEach(function (_c, i) {
        var b = document.createElement('button');
        b.type = 'button';
        b.setAttribute('aria-label', '第' + (i + 1) + '张');
        b.addEventListener('click', function () {
          if (!expanded) goTo(i);
        });
        dotsBox.appendChild(b);
      });
    }

    function updateDots() {
      if (!dotsBox) return;
      Array.prototype.forEach.call(dotsBox.children, function (dot, i) {
        dot.setAttribute('aria-current', i === index ? 'true' : 'false');
      });
    }

    function stackOffset(i, active) {
      var n = cards.length;
      var d = i - active;
      if (d > n / 2) d -= n;
      if (d < -n / 2) d += n;
      return d;
    }

    function activeMeta() {
      var a = cards[index];
      if (!a) return;
      var type = a.getAttribute('data-type') || '';
      var sub = a.getAttribute('data-sub') || '';
      if (nameEl) nameEl.textContent = type;
      if (subEl) subEl.textContent = sub;
      if (nameHint) nameHint.textContent = type;
    }

    // 牌堆锚点：略偏左、整体下移
    function stackAnchor() {
      return {
        cx: viewport.clientWidth * 0.46,
        cy: viewport.clientHeight * 0.58
      };
    }

    function layoutDeck(dragX) {
      var anchor = stackAnchor();
      var cx = anchor.cx;
      var cy = anchor.cy;
      var dx = dragX || 0;

      cards.forEach(function (card, i) {
        var d = stackOffset(i, index);
        var abs = Math.abs(d);
        var z = 50 - abs;
        var side = d === 0 ? dx : d * (cardW * 0.2) + dx * 0.35;
        var scale = d === 0 ? 1 : 1 - abs * 0.055;
        var rot = d * 3.5 + (dx / cardW) * 5;
        var ty = abs * 7;
        var opacity = d === 0 ? 1 : Math.max(0.14, 0.55 - abs * 0.08);

        card.style.pointerEvents = d === 0 ? 'auto' : 'none';
        card.style.zIndex = String(z);
        card.style.opacity = String(opacity);
        card.style.transform =
          'translate(' + (cx - cardW / 2 + side) + 'px,' +
          (cy - cardH / 2 + ty) + 'px) rotate(' + rot + 'deg) scale(' + scale + ')';
      });

      activeMeta();
      updateDots();
    }

    function clearInlineForExpand() {
      cards.forEach(function (card) {
        card.classList.remove('is-instant');
        card.style.transition = '';
        card.style.transitionDelay = '';
        card.style.transform = '';
        card.style.opacity = '';
        card.style.zIndex = '';
        card.style.pointerEvents = 'auto';
        card.style.transformOrigin = 'top left';
      });
    }

    function applyStackTransforms() {
      var anchor = stackAnchor();
      var cx = anchor.cx;
      var cy = anchor.cy;
      cards.forEach(function (card, i) {
        var d = stackOffset(i, index);
        var abs = Math.abs(d);
        var side = d * (cardW * 0.2);
        var scale = d === 0 ? 1 : 1 - abs * 0.055;
        var rot = d * 3.5;
        var ty = abs * 7;
        var opacity = d === 0 ? 1 : Math.max(0.2, 0.55 - abs * 0.08);
        card.style.position = 'absolute';
        card.style.width = cardW + 'px';
        card.style.height = cardH + 'px';
        card.style.zIndex = String(50 - abs);
        card.style.opacity = String(opacity);
        card.style.pointerEvents = d === 0 ? 'auto' : 'none';
        card.style.transform =
          'translate(' + (cx - cardW / 2 + side) + 'px,' +
          (cy - cardH / 2 + ty) + 'px) rotate(' + rot + 'deg) scale(' + scale + ')';
      });
    }

    function goTo(next) {
      var n = cards.length;
      index = ((next % n) + n) % n;
      if (expanded) {
        cards.forEach(function (c, i) {
          c.style.boxShadow = i === index
            ? '0 0 0 2px var(--accent), 0 8px 20px rgba(10,89,247,0.15)'
            : '0 6px 18px rgba(28,25,23,0.06)';
        });
        activeMeta();
        updateDots();
        return;
      }
      layoutDeck(0);
    }

    function flipExpand() {
      if (animating) return;
      animating = true;

      var n = cards.length;
      var first = cards.map(function (c) { return c.getBoundingClientRect(); });
      expanded = !expanded;
      stage.classList.toggle('is-expanded', expanded);
      root.classList.toggle('is-wide', expanded);

      if (toggleBtn) {
        toggleBtn.classList.toggle('is-expanded', expanded);
        toggleBtn.setAttribute('aria-expanded', expanded ? 'true' : 'false');
      }
      if (toggleText) {
        toggleText.textContent = expanded ? '收回叠放' : '展开全部';
      }

      if (expanded) {
        clearInlineForExpand();
        cards.forEach(function (c, i) {
          c.style.boxShadow = i === index
            ? '0 0 0 2px var(--accent), 0 8px 20px rgba(10,89,247,0.15)'
            : '0 6px 18px rgba(28,25,23,0.06)';
        });
      } else {
        clearInlineForExpand();
        cards.forEach(function (c) { c.style.boxShadow = ''; });
        applyStackTransforms();
      }

      var endTransforms = cards.map(function (c) { return c.style.transform; });
      var endOpacities = cards.map(function (c) { return c.style.opacity; });
      var last = cards.map(function (c) { return c.getBoundingClientRect(); });

      // 所有卡片都参与：Invert 到切换前位置
      cards.forEach(function (card, i) {
        var f = first[i];
        var l = last[i];
        if (!l || !l.width || !l.height) {
          return;
        }
        // 无 first 时从牌堆侧飞入
        var fx = f ? f.left : l.left + (expanded ? 40 : -40);
        var fy = f ? f.top : l.top + 24;
        var fw = f && f.width ? f.width : l.width;
        var fh = f && f.height ? f.height : l.height;
        var dx = fx - l.left;
        var dy = fy - l.top;
        var sx = fw / l.width;
        var sy = fh / l.height;
        card.classList.add('is-instant');
        card.style.transformOrigin = 'top left';
        card.style.transform = 'translate(' + dx + 'px,' + dy + 'px) scale(' + sx + ',' + sy + ')';
        card.style.opacity = String(Math.min(0.9, Math.max(0.15, (f && f.width) ? 0.75 : 0.2)));
      });

      void stage.offsetHeight;

      // 全卡展开：错峰更顺；收回反向错峰
      var EASE = 'cubic-bezier(0.32, 0.72, 0, 1)';
      var DUR = 780;

      requestAnimationFrame(function () {
        cards.forEach(function (card, i) {
          card.classList.remove('is-instant');
          var delay = expanded ? i * 36 : (n - 1 - i) * 32;
          card.style.transition =
            'transform ' + DUR + 'ms ' + EASE + ', opacity ' + Math.round(DUR * 0.85) + 'ms ' + EASE;
          card.style.transitionDelay = delay + 'ms';
          card.style.transformOrigin = 'top left';

          if (expanded) {
            card.style.transform = '';
            card.style.opacity = '1';
          } else {
            card.style.transform = endTransforms[i] || '';
            card.style.opacity = endOpacities[i] !== undefined && endOpacities[i] !== ''
              ? endOpacities[i] : '1';
          }
        });

        window.setTimeout(function () {
          cards.forEach(function (card) {
            card.classList.remove('is-instant');
            card.style.transition = '';
            card.style.transitionDelay = '';
            card.style.transformOrigin = 'center center';
          });
          if (!expanded) {
            layoutDeck(0);
          } else {
            activeMeta();
            updateDots();
          }
          fitAll();
          animating = false;
        }, DUR + n * 36 + 40);
      });
    }

    if (toggleBtn) {
      toggleBtn.addEventListener('click', flipExpand);
    }
    if (prevBtn) prevBtn.addEventListener('click', function () { goTo(index - 1); });
    if (nextBtn) nextBtn.addEventListener('click', function () { goTo(index + 1); });

    var dragging = false;
    var startX = 0;
    var lastX = 0;
    var baseIndex = 0;

    viewport.addEventListener('pointerdown', function (e) {
      if (expanded || animating) return;
      if (e.button !== undefined && e.button !== 0) return;
      dragging = true;
      startX = e.clientX;
      lastX = e.clientX;
      baseIndex = index;
      viewport.classList.add('is-dragging');
      cards.forEach(function (c) { c.style.transition = 'none'; });
      try { viewport.setPointerCapture(e.pointerId); } catch (_) {}
    });
    viewport.addEventListener('pointermove', function (e) {
      if (!dragging || expanded) return;
      lastX = e.clientX;
      layoutDeck(lastX - startX);
    });
    function onUp() {
      if (!dragging) return;
      dragging = false;
      viewport.classList.remove('is-dragging');
      cards.forEach(function (c) { c.style.transition = ''; });
      var dx = lastX - startX;
      var threshold = Math.min(72, cardW * 0.2);
      if (dx <= -threshold) goTo(baseIndex + 1);
      else if (dx >= threshold) goTo(baseIndex - 1);
      else layoutDeck(0);
    }
    viewport.addEventListener('pointerup', onUp);
    viewport.addEventListener('pointercancel', onUp);

    root.tabIndex = 0;
    root.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowLeft') { e.preventDefault(); goTo(index - 1); }
      if (e.key === 'ArrowRight') { e.preventDefault(); goTo(index + 1); }
    });

    layoutDeck(0);

    if (typeof ResizeObserver !== 'undefined') {
      var ro = new ResizeObserver(function () {
        if (!expanded) layoutDeck(0);
        fitAll();
      });
      ro.observe(viewport);
    }
  }

  function boot() {
    cloneCardsFromPad();
    bindAllDropZones();
    Array.prototype.forEach.call(document.querySelectorAll('[data-deck]'), initDeck);
    activateMode('pad');
    fitAll();
    window.addEventListener('load', fitAll);
    window.addEventListener('resize', function () {
      clearTimeout(window.__fitT);
      window.__fitT = setTimeout(fitAll, 80);
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
