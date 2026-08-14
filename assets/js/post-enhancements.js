(function () {
  var content = document.querySelector('.post-content');
  var urlPattern = /https?:\/\/[^\s<>"']*[^\s<>"'.,;:!?)]/g;
  var ignoredParents = new Set(['A', 'CODE', 'PRE', 'SCRIPT', 'STYLE', 'TEXTAREA']);

  function linkifyTextNode(node) {
    var text = node.nodeValue;
    if (!urlPattern.test(text)) {
      urlPattern.lastIndex = 0;
      return;
    }
    urlPattern.lastIndex = 0;

    var fragment = document.createDocumentFragment();
    var lastIndex = 0;
    var match;

    while ((match = urlPattern.exec(text)) !== null) {
      var url = match[0];
      if (match.index > lastIndex) {
        fragment.appendChild(document.createTextNode(text.slice(lastIndex, match.index)));
      }

      var anchor = document.createElement('a');
      anchor.href = url;
      anchor.textContent = url;
      anchor.className = 'link-preview-anchor';
      fragment.appendChild(anchor);
      lastIndex = match.index + url.length;
    }

    if (lastIndex < text.length) {
      fragment.appendChild(document.createTextNode(text.slice(lastIndex)));
    }

    node.parentNode.replaceChild(fragment, node);
  }

  function linkifyPlainUrls(root) {
    if (!root) {
      return;
    }

    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        var parent = node.parentElement;
        while (parent && parent !== root) {
          if (ignoredParents.has(parent.tagName)) {
            return NodeFilter.FILTER_REJECT;
          }
          parent = parent.parentElement;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });

    var nodes = [];
    while (walker.nextNode()) {
      nodes.push(walker.currentNode);
    }
    nodes.forEach(linkifyTextNode);
  }

  function externalizeLinks(root) {
    if (!root) {
      return;
    }

    root.querySelectorAll('a[href^="http://"], a[href^="https://"]').forEach(function (anchor) {
      anchor.classList.add('link-preview-anchor');
      anchor.target = '_blank';
      anchor.rel = 'noopener noreferrer';
    });
  }

  function compactUrl(url) {
    try {
      var parsed = new URL(url);
      var path = parsed.pathname === '/' ? '' : parsed.pathname;
      return {
        origin: parsed.hostname.replace(/^www\./, ''),
        path: (path + parsed.search).slice(0, 96),
        href: parsed.href
      };
    } catch (error) {
      return {
        origin: 'External link',
        path: url,
        href: url
      };
    }
  }

  function titleFromAnchor(anchor, info) {
    var text = anchor.textContent.trim();
    if (!text || text === info.href) {
      return info.origin + (info.path ? info.path : '');
    }
    if (text.indexOf('http://') === 0 || text.indexOf('https://') === 0) {
      return info.origin + (info.path ? info.path : '');
    }
    return text;
  }

  function faviconUrl(href) {
    try {
      var parsed = new URL(href);
      return 'https://www.google.com/s2/favicons?domain=' + encodeURIComponent(parsed.hostname) + '&sz=32';
    } catch (error) {
      return '';
    }
  }

  function transformStandaloneLinks(root) {
    if (!root) {
      return;
    }

    root.querySelectorAll('p, li').forEach(function (block) {
      if (block.querySelector('img, pre, code, table')) {
        return;
      }

      var links = Array.prototype.slice.call(block.querySelectorAll('a[href^="http://"], a[href^="https://"]'));
      if (links.length !== 1) {
        return;
      }

      var anchor = links[0];
      var text = block.textContent.trim();
      var href = anchor.href;
      var compactText = text.replace(/\s+/g, ' ');
      var compactHref = anchor.textContent.trim().replace(/\s+/g, ' ');
      var isBareLine = compactText === compactHref || compactText.length <= compactHref.length + 32;

      if (!isBareLine) {
        return;
      }

      var info = compactUrl(href);
      var card = document.createElement('a');
      card.href = href;
      card.target = '_blank';
      card.rel = 'noopener noreferrer';
      card.className = 'inline-link-preview link-preview-anchor';

      var icon = document.createElement('span');
      icon.className = 'inline-link-preview-icon';
      var image = document.createElement('img');
      image.src = faviconUrl(href);
      image.alt = '';
      image.loading = 'lazy';
      icon.appendChild(image);

      var title = document.createElement('span');
      title.className = 'inline-link-preview-title';
      title.textContent = titleFromAnchor(anchor, info);

      card.appendChild(icon);
      card.appendChild(title);
      block.textContent = '';
      block.appendChild(card);
      block.classList.add('inline-link-preview-block');
    });
  }

  function createPreview() {
    var preview = document.createElement('aside');
    preview.className = 'link-preview-card';
    preview.setAttribute('aria-hidden', 'true');
    preview.innerHTML = [
      '<div class="link-preview-label">LINK</div>',
      '<div class="link-preview-title"></div>',
      '<div class="link-preview-url"></div>'
    ].join('');
    document.body.appendChild(preview);
    return preview;
  }

  function attachPreview(root) {
    if (!root) {
      return;
    }

    var preview = createPreview();
    var title = preview.querySelector('.link-preview-title');
    var url = preview.querySelector('.link-preview-url');

    function show(anchor) {
      var info = compactUrl(anchor.href);
      title.textContent = info.origin;
      url.textContent = info.path || info.href;

      var rect = anchor.getBoundingClientRect();
      var top = window.scrollY + rect.bottom + 10;
      var left = window.scrollX + Math.min(rect.left, window.innerWidth - 340);
      preview.style.top = top + 'px';
      preview.style.left = Math.max(12, left) + 'px';
      preview.setAttribute('aria-hidden', 'false');
    }

    function hide() {
      preview.setAttribute('aria-hidden', 'true');
    }

    root.querySelectorAll('.link-preview-anchor').forEach(function (anchor) {
      anchor.addEventListener('mouseenter', function () {
        show(anchor);
      });
      anchor.addEventListener('focus', function () {
        show(anchor);
      });
      anchor.addEventListener('mouseleave', hide);
      anchor.addEventListener('blur', hide);
    });
  }

  linkifyPlainUrls(content);
  externalizeLinks(content);
  transformStandaloneLinks(content);
  attachPreview(content);
}());
