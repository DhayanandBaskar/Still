(() => {
  'use strict';
  const welcome = document.getElementById('welcome');
  const page = document.getElementById('document');
  const article = document.getElementById('article');
  const bridge = message => window.webkit?.messageHandlers?.reader?.postMessage(message);
  let scrollTimer;
  let hintTimer;
  let headingElements = [];
  let activeHeading = null;
  let headingTimer;
  let rendering = false;
  let documentLoaded = false;
  marked.setOptions({ gfm: true, breaks: false, async: false });

  const ratio = () => {
    const height = document.documentElement.scrollHeight - window.innerHeight;
    return height > 0 ? Math.min(1, Math.max(0, window.scrollY / height)) : 0;
  };

  function decorate() {
    const headings = [];
    headingElements = Array.from(article.querySelectorAll('h1,h2,h3,h4,h5,h6'));
    headingElements.forEach((heading, index) => {
      const id = `still-heading-${index}`;
      heading.id = id;
      headings.push({ text: heading.textContent, id, level: Number(heading.tagName[1]) });
    });
    article.querySelectorAll('input').forEach(input => {
      if (input.type === 'checkbox') {
        const box = document.createElement('span');
        box.className = `task-box${input.checked ? ' checked' : ''}`;
        box.setAttribute('role', 'img');
        box.setAttribute('aria-label', input.checked ? 'Completed' : 'Not completed');
        input.closest('li')?.classList.add('task-item');
        input.closest('ul')?.classList.add('task-list');
        input.replaceWith(box);
      } else { input.remove(); }
    });
    article.querySelectorAll('pre code').forEach(code => {
      const language = code.className.match(/language-([\w#+.-]+)/)?.[1];
      if (!language) return;
      const label = document.createElement('span');
      label.className = 'code-language';
      label.textContent = language;
      label.setAttribute('aria-hidden', 'true');
      code.parentElement.prepend(label);
    });
    article.querySelectorAll('table').forEach(table => {
      const wrapper = document.createElement('div');
      wrapper.className = 'table-wrap';
      wrapper.tabIndex = 0;
      wrapper.setAttribute('role', 'region');
      wrapper.setAttribute('aria-label', 'Scrollable table');
      table.replaceWith(wrapper);
      wrapper.append(table);
    });
    article.querySelectorAll('img').forEach(img => {
      const source = img.getAttribute('src') || '';
      if (!source) return;
      // Relative assets go through a native image-only handler. Absolute local paths are rejected.
      if (!/^(https?:|data:image\/)/i.test(source)) {
        if (/^[a-z][a-z\d+.-]*:/i.test(source) || source.startsWith('/') || source.startsWith('\\')) {
          img.removeAttribute('src');
        } else {
          const path = source.split(/[?#]/)[0];
          let decoded;
          try { decoded = decodeURIComponent(path); } catch { decoded = path; }
          img.setAttribute('src', `still-image://document/${encodeURIComponent(decoded)}`);
        }
      }
      img.addEventListener('error', () => {
        img.classList.add('failed-image');
        if (!img.alt) img.alt = 'Image unavailable';
      }, { once: true });
    });
    bridge({ action: 'headings', items: headings });
  }

  window.still = Object.freeze({
    render(markdown, filename, position) {
      rendering = true;
      activeHeading = null;
      const target = typeof position === 'number' ? position : ratio();
      const normalized = markdown.replace(/^\uFEFF/, '');
      const html = marked.parse(normalized);
      article.innerHTML = DOMPurify.sanitize(html, {
        USE_PROFILES: { html: true },
        FORBID_TAGS: ['style', 'script', 'iframe', 'object', 'embed', 'form', 'button', 'select', 'textarea', 'audio', 'video'],
        FORBID_ATTR: ['style', 'srcset', 'id', 'name', 'contenteditable', 'autofocus', 'tabindex'],
        ADD_TAGS: ['input'],
        ADD_ATTR: ['type', 'checked', 'disabled'],
        ALLOW_DATA_ATTR: false,
      });
      decorate();
      document.getElementById('file-label').textContent = filename.replace(/\.(md|markdown)$/i, '');
      const words = article.textContent.trim().split(/\s+/).filter(Boolean).length;
      const minutes = Math.max(1, Math.ceil(words / 220));
      document.getElementById('reading-time').textContent = `${minutes} min read`;
      document.getElementById('empty-document').hidden = Boolean(article.textContent.trim() || article.querySelector('img,hr,table'));
      welcome.hidden = true;
      page.hidden = false;
      documentLoaded = true;
      updateActiveHeading();
      requestAnimationFrame(() => {
        const restore = () => window.scrollTo(0, Math.max(0, (document.documentElement.scrollHeight - innerHeight) * target));
        restore();
        // Keep the saved position stable after local or remote images finish sizing.
        for (const image of article.querySelectorAll('img')) {
          if (!image.complete) image.addEventListener('load', () => { if (rendering) restore(); }, { once: true });
        }
        setTimeout(() => { rendering = false; updateProgress(); }, 180);
      });
      return { words, headings: article.querySelectorAll('h1,h2,h3,h4,h5,h6').length };
    },
    preferences(theme, typeface, size) {
      const saved = ratio();
      document.documentElement.dataset.theme = ['paper', 'dusk', 'system'].includes(theme) ? theme : 'system';
      document.documentElement.dataset.typeface = typeface === 'serif' ? 'serif' : 'sans';
      document.documentElement.style.setProperty('--body-size', `${Math.max(14, Math.min(28, size))}px`);
      if (documentLoaded) requestAnimationFrame(() => window.scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * saved));
    },
    focus(enabled) {
      document.body.classList.toggle('focus', enabled);
      const hint = document.getElementById('focus-hint');
      clearTimeout(hintTimer);
      hint.classList.toggle('visible', enabled);
      if (enabled) hintTimer = setTimeout(() => hint.classList.remove('visible'), 2300);
    },
    jump(id) { document.getElementById(id)?.scrollIntoView({ behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth', block: 'start' }); },
    empty() {
      article.replaceChildren();
      headingElements = [];
      activeHeading = null;
      bridge({ action: 'activeHeading', id: null });
      page.hidden = true;
      welcome.hidden = false;
      documentLoaded = false;
      window.scrollTo(0, 0);
      updateProgress();
    },
  });

  function updateActiveHeading() {
    headingTimer = null;
    if (!documentLoaded) return;
    let current = headingElements[0];
    for (const heading of headingElements) {
      if (heading.getBoundingClientRect().top <= 90) current = heading;
      else break;
    }
    if (headingElements.length && ratio() >= 0.998) current = headingElements[headingElements.length - 1];
    const id = current?.id || null;
    if (id !== activeHeading) { activeHeading = id; bridge({ action: 'activeHeading', id }); }
  }
  function updateProgress() {
    document.getElementById('progress').style.width = documentLoaded ? `${ratio() * 100}%` : '0';
    if (headingTimer == null) headingTimer = setTimeout(updateActiveHeading, 40);
  }
  document.getElementById('open-file').addEventListener('click', () => bridge({ action: 'open' }));
  document.addEventListener('keydown', event => { if (event.key === 'Escape') bridge({ action: 'escape' }); });
  document.addEventListener('click', event => {
    const link = event.target.closest('a');
    if (!link) return;
    event.preventDefault();
    const href = link.getAttribute('href') || '';
    if (href.startsWith('#')) {
      let fragment;
      try { fragment = decodeURIComponent(href.slice(1)); } catch { return; }
      const slug = text => text.toLowerCase().replace(/[^\p{L}\p{N}_\s-]/gu, '').trim().replace(/\s/g, '-');
      const heading = Array.from(article.querySelectorAll('h1,h2,h3,h4,h5,h6')).find(h => h.id === fragment || slug(h.textContent) === fragment);
      heading?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    } else { bridge({ action: 'link', url: href }); }
  });
  // Files are rendered as content only; no editable DOM, document scripts, or form submission.
  document.addEventListener('submit', event => event.preventDefault());
  window.addEventListener('scroll', () => {
    updateProgress();
    clearTimeout(scrollTimer);
    if (documentLoaded && !rendering) scrollTimer = setTimeout(() => bridge({ action: 'scroll', position: ratio() }), 180);
  }, { passive: true });
  window.addEventListener('resize', updateProgress);
  bridge({ action: 'ready' });
})();
