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
  const adSelectors = [
    '#tads',
    '#tadsb',
    '#bottomads',
    '[data-text-ad]',
    '.uEierd',
    'ins.adsbygoogle',
    'iframe[src*="googlesyndication.com"]',
    'iframe[src*="doubleclick.net"]',
    'iframe[src*="googleadservices.com"]',
    'iframe[id^="google_ads_iframe_"]',
    'div[id^="google_ads_iframe_"]',
    'div[id^="div-gpt-ad"]'
  ];

  const labelPattern = /\bAI\s+Overview\b/i;
  const supportingPattern = /\bGenerative AI is experimental\b/i;
  const adLabelPattern = /^(ad|ads|sponsored)$/i;

  const hide = (element) => {
    if (!(element instanceof HTMLElement) || element.hasAttribute(hiddenAttr)) {
      return;
    }
    element.setAttribute(hiddenAttr, 'true');
    element.setAttribute('aria-hidden', 'true');
    element.style.setProperty('display', 'none', 'important');
    element.style.setProperty('visibility', 'hidden', 'important');
    element.style.setProperty('height', '0', 'important');
    element.style.setProperty('min-height', '0', 'important');
    element.style.setProperty('margin', '0', 'important');
    element.style.setProperty('padding', '0', 'important');
  };

  const installStyle = () => {
    if (document.getElementById('helium-content-blocker-style')) {
      return;
    }
    const style = document.createElement('style');
    style.id = 'helium-content-blocker-style';
    style.textContent = `${adSelectors.join(',')}{display:none!important;visibility:hidden!important;height:0!important;min-height:0!important;margin:0!important;padding:0!important;}`;
    (document.head || document.documentElement).appendChild(style);
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

  const findAdContainer = (element) => {
    const direct = element.closest('[data-text-ad],.uEierd,#tads,#tadsb,#bottomads,[aria-label="Ads"],[aria-label="Sponsored"]');
    if (direct instanceof HTMLElement) {
      return direct;
    }

    let cursor = element;
    let last = element;
    for (let depth = 0; depth < 6 && cursor.parentElement; depth += 1) {
      if (cursor.parentElement.id === 'search' || cursor.parentElement.id === 'rso') {
        return cursor;
      }
      last = cursor.parentElement;
      cursor = cursor.parentElement;
    }
    return last;
  };

  const scan = () => {
    installStyle();

    for (const selector of rootSelectors) {
      for (const element of document.querySelectorAll(selector)) {
        if (element instanceof HTMLElement && textLooksLikeAiOverview(element)) {
          hide(findContainer(element));
        }
      }
    }

    for (const selector of adSelectors) {
      for (const element of document.querySelectorAll(selector)) {
        hide(element);
      }
    }

    for (const element of document.querySelectorAll('h1,h2,h3,span,div')) {
      const normalized = (element.textContent || '').replace(/\s+/g, ' ').trim();
      if (!(element instanceof HTMLElement) || !(labelPattern.test(element.textContent || '') || adLabelPattern.test(normalized))) {
        continue;
      }
      if (normalized === 'AI Overview') {
        hide(findContainer(element));
      } else if (adLabelPattern.test(normalized)) {
        hide(findAdContainer(element));
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
