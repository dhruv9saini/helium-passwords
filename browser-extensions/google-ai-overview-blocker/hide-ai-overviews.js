(() => {
  'use strict';

  if (location.hostname !== 'www.google.com' || location.pathname !== '/search') {
    return;
  }

  document.documentElement.setAttribute('data-helium-ai-overview-blocker', 'active');

  const hiddenAttr = 'data-helium-hidden-ai-overview';
  const rootSelectors = [
    '[data-subtree="mfc"]',
    '[data-aquarium]',
    '.YzCcne',
    '.GcKpu',
    '.hdzaWe',
    '.dRpWwb.M8OgIe.bzXtMb',
    'style + div[data-mcpr][style^="margin-bottom:"]'
  ];

  const labelPattern = /\bAI\s+Overview\b/i;
  const supportingPattern = /\bGenerative AI is experimental\b/i;

  const hide = (element) => {
    if (!(element instanceof HTMLElement) || element.hasAttribute(hiddenAttr)) {
      return;
    }
    element.setAttribute(hiddenAttr, 'true');
    element.style.setProperty('display', 'none', 'important');
  };

  const textLooksLikeAiOverview = (element) => {
    const text = (element.textContent || '').slice(0, 1200);
    return labelPattern.test(text) || supportingPattern.test(text);
  };

  const findContainer = (element) => {
    for (const selector of rootSelectors) {
      const container = element.closest(selector);
      if (container instanceof HTMLElement) {
        return container;
      }
    }

    let cursor = element;
    let last = element;
    for (let depth = 0; depth < 8 && cursor.parentElement; depth += 1) {
      if (cursor.parentElement.id === 'search' || cursor.parentElement.id === 'rso') {
        return cursor;
      }
      last = cursor.parentElement;
      cursor = cursor.parentElement;
    }
    return last;
  };

  const scan = () => {
    for (const selector of rootSelectors) {
      for (const element of document.querySelectorAll(selector)) {
        if (element instanceof HTMLElement && textLooksLikeAiOverview(element)) {
          hide(findContainer(element));
        }
      }
    }

    for (const element of document.querySelectorAll('h1,h2,h3,span,div')) {
      if (!(element instanceof HTMLElement) || !labelPattern.test(element.textContent || '')) {
        continue;
      }
      const normalized = (element.textContent || '').replace(/\s+/g, ' ').trim();
      if (normalized === 'AI Overview') {
        hide(findContainer(element));
      }
    }
  };

  const scheduleScan = (() => {
    let pending = false;
    return () => {
      if (pending) {
        return;
      }
      pending = true;
      requestAnimationFrame(() => {
        pending = false;
        scan();
      });
    };
  })();

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', scheduleScan, { once: true });
  } else {
    scheduleScan();
  }

  new MutationObserver(scheduleScan).observe(document.documentElement, {
    childList: true,
    subtree: true
  });
})();
