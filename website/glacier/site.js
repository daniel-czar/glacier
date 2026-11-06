/* Glacier public site interactions: toolkit examples, navigation, recording, tool catalogue. */
(() => {
  'use strict';
  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  const examples = {
    ratio: {
      html: `<div class="toolkit-native"><div class="toolkit-native-title"><span>16:9 at 1200 wide</span><b>Ratio</b></div><div class="toolkit-ratio"><div class="toolkit-ratio-drawing"><small>1200 px</small>16:9</div><div class="toolkit-ratio-answer"><strong>1200 × 675</strong><span>Width × height · pixels</span></div></div><div class="toolkit-native-footer"><span>Calculated locally</span><strong>↵ Copy dimensions</strong></div></div>`,
      explanation: 'Type <kbd>ra</kbd> then <kbd>Tab</kbd> to open Ratio. <kbd>Return</kbd> copies the dimensions and closes the tool. No model or network needed.'
    },
    map: {
      html: `<div class="toolkit-native"><div class="toolkit-native-title"><span>Walk vs bike vs train</span><b>Map · Matrix</b></div><div class="toolkit-matrix"><table><caption class="sr-only">Illustrated comparison for a city trip</caption><thead><tr><th scope="col">Travel</th><th scope="col">Range</th><th scope="col">Schedule</th></tr></thead><tbody><tr><th scope="row">Walk</th><td>Short trips</td><td>Any time</td></tr><tr><th scope="row">Bike</th><td>Across town</td><td>Any time</td></tr><tr><th scope="row">Train</th><td>Longer trips</td><td>Timetabled</td></tr></tbody></table></div><div class="toolkit-native-footer"><span>Illustrative · routes vary</span><strong>↵ Copy image + text</strong></div></div>`,
      explanation: 'Type <kbd>mp</kbd> then <kbd>Tab</kbd> to open Map. Ask a question and choose a form; <kbd>Return</kbd> copies the resulting diagram as an image and text.'
    },
    regex: {
      html: `<div class="toolkit-native"><div class="toolkit-native-title"><span>^\\d{4}-\\d{2}-\\d{2}$</span><b>Regex</b></div><div class="toolkit-regex"><div class="toolkit-railroad" aria-label="Four digits, dash, two digits, dash, two digits"><span>digit ×4</span><i></i>−<i></i><span>digit ×2</span><i></i>−<i></i><span>digit ×2</span></div><div class="toolkit-regex-tests"><span>✓ 2026-11-02</span><span class="fail">× 02/11/2026</span></div></div><div class="toolkit-native-footer"><span>Checks shape, not valid dates</span><strong>↵ Copy pattern</strong></div></div>`,
      explanation: 'Type <kbd>rx</kbd> then <kbd>Tab</kbd> to open Regex. Enter a pattern or describe one. Glacier checks examples locally; a model can draft a pattern when you ask.'
    }
  };
  const result = $('#tool-result');
  const explanation = $('#tool-explanation');
  const exampleButtons = $$('[data-opening-tool]');
  function chooseExample(name) {
    const example = examples[name];
    if (!example || !result || !explanation) return;
    result.innerHTML = example.html;
    explanation.innerHTML = example.explanation;
    exampleButtons.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.openingTool === name)));
  }
  exampleButtons.forEach(button => button.addEventListener('click', () => chooseExample(button.dataset.openingTool)));
  chooseExample('ratio');

  const navMenu = $('#nav-menu');
  const navLinks = $('#nav-links');
  if (navMenu && navLinks) {
    const setOpen = open => { navLinks.classList.toggle('is-open', open); navMenu.setAttribute('aria-expanded', String(open)); };
    navMenu.addEventListener('click', () => setOpen(!navLinks.classList.contains('is-open')));
    navLinks.addEventListener('click', event => { if (event.target.closest('a')) setOpen(false); });
    document.addEventListener('keydown', event => { if (event.key === 'Escape' && navLinks.classList.contains('is-open')) { setOpen(false); navMenu.focus(); } });
    document.addEventListener('click', event => { if (navLinks.classList.contains('is-open') && !event.target.closest('.nav-row')) setOpen(false); });
  }

  const real = $('#real');
  const recVideo = $('#rec-video');
  const recToggle = $('#rec-toggle');
  if (real && recVideo) {
    let pausedByUser = false;
    let inView = false;
    const pauseState = pause => {
      pausedByUser = pause;
      if (recToggle) { recToggle.setAttribute('aria-pressed', String(pause)); const label = $('span', recToggle); if (label) label.textContent = pause ? 'Play' : 'Pause'; }
      if (pause) recVideo.pause(); else if (inView) recVideo.play().catch(() => {});
    };
    const show = () => {
      real.hidden = false;
      if (reduceMotion) { recVideo.controls = true; recVideo.removeAttribute('loop'); if (recToggle) recToggle.hidden = true; return; }
      if ('IntersectionObserver' in window) {
        new IntersectionObserver(entries => { inView = entries[0].isIntersecting; if (inView && !pausedByUser) recVideo.play().catch(() => {}); else recVideo.pause(); }, { threshold: 0.4 }).observe(recVideo);
      } else { inView = true; recVideo.play().catch(() => {}); }
      document.addEventListener('visibilitychange', () => { if (document.hidden) recVideo.pause(); else if (inView && !pausedByUser) recVideo.play().catch(() => {}); });
      recToggle?.addEventListener('click', () => pauseState(!pausedByUser));
      recVideo.addEventListener('click', () => pauseState(!pausedByUser));
    };
    recVideo.addEventListener('loadedmetadata', show, { once: true });
    recVideo.addEventListener('error', () => { recVideo.controls = true; if (recToggle) recToggle.hidden = true; });
    recVideo.load();
  }

  const toolList = $('#tool-list');
  const toolStage = $('#tool-stage');
  if (toolList && toolStage) {
    const tabs = $$('.tool-row', toolList);
    const panels = $$('.tool-panel', toolStage);
    const stacked = window.matchMedia('(max-width: 1100px)');
    const pick = (name, focus = false) => {
      tabs.forEach(tab => { const active = tab.dataset.tool === name; tab.setAttribute('aria-selected', String(active)); tab.tabIndex = active ? 0 : -1; if (active && focus) tab.focus(); });
      panels.forEach(panel => { const active = panel.dataset.tool === name; panel.hidden = !active; panel.classList.toggle('is-on', active); panel.setAttribute('aria-hidden', String(!active)); });
      sizeStage();
    };
    const sizeStage = () => {
      if (stacked.matches) { toolStage.style.minHeight = ''; return; }
      const height = Math.max(0, ...panels.map(panel => panel.scrollHeight));
      toolStage.style.minHeight = `${height}px`;
    };
    const orient = () => { toolList.setAttribute('aria-orientation', stacked.matches ? 'horizontal' : 'vertical'); sizeStage(); };
    stacked.addEventListener('change', orient);
    tabs.forEach(tab => {
      tab.addEventListener('click', () => pick(tab.dataset.tool));
      tab.addEventListener('keydown', event => {
        const index = tabs.indexOf(tab);
        const columns = stacked.matches ? getComputedStyle(toolList).gridTemplateColumns.split(' ').length : 1;
        let next = null;
        if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
        if (event.key === 'ArrowLeft') next = (index - 1 + tabs.length) % tabs.length;
        if (event.key === 'ArrowDown') next = (index + columns) % tabs.length;
        if (event.key === 'ArrowUp') next = (index - columns + tabs.length) % tabs.length;
        if (event.key === 'Home') next = 0;
        if (event.key === 'End') next = tabs.length - 1;
        if (next !== null) { event.preventDefault(); pick(tabs[next].dataset.tool, true); }
      });
    });
    pick('qr'); orient();
    if ('ResizeObserver' in window) new ResizeObserver(sizeStage).observe(toolStage);
    else window.addEventListener('resize', sizeStage);
  }

  const reveals = $$('.reveal');
  if ('IntersectionObserver' in window && !reduceMotion) {
    const observer = new IntersectionObserver(entries => { entries.forEach(entry => { if (entry.isIntersecting) { entry.target.classList.add('in'); observer.unobserve(entry.target); } }); }, { threshold: 0.15, rootMargin: '0px 0px -40px 0px' });
    reveals.forEach(element => observer.observe(element));
  } else reveals.forEach(element => element.classList.add('in'));
})();
