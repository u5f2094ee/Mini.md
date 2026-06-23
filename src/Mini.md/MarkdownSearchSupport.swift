import Foundation

enum MarkdownSearchSupport {
    static func append(to html: String) -> String {
        guard let bodyCloseRange = html.range(of: "</body>", options: [.caseInsensitive, .backwards]) else {
            return html + supportHTML
        }

        var adjustedHTML = html
        adjustedHTML.insert(contentsOf: supportHTML, at: bodyCloseRange.lowerBound)
        return adjustedHTML
    }

    private static let supportHTML = #"""
    <style>
    mark.mini-md-search-hit {
      background: #ffe58a;
      color: inherit;
      border-radius: 2px;
      padding: 0 1px;
    }

    mark.mini-md-search-active {
      background: #ffb13b;
      box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.28);
    }

    html[data-theme="dark"] mark.mini-md-search-hit {
      background: rgba(255, 217, 102, 0.45);
    }

    html[data-theme="dark"] mark.mini-md-search-active {
      background: rgba(255, 159, 43, 0.75);
      box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.26);
    }
    </style>
    <script>
    (function () {
      if (window.miniMDSearch) {
        return;
      }

      const hitClass = 'mini-md-search-hit';
      const activeClass = 'mini-md-search-active';
      const skippedTags = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'IFRAME', 'OBJECT', 'SVG', 'CANVAS', 'INPUT', 'TEXTAREA', 'SELECT', 'OPTION']);
      let matches = [];
      let activeIndex = -1;

      function state() {
        return { count: matches.length, index: activeIndex };
      }

      function restoreScroll(x, y) {
        window.scrollTo(x, y);
        window.requestAnimationFrame(function () {
          window.scrollTo(x, y);
        });
      }

      function clear(preserveScroll) {
        const x = window.scrollX;
        const y = window.scrollY;
        const parents = new Set();
        document.querySelectorAll('mark.' + hitClass).forEach(function (mark) {
          const parent = mark.parentNode;
          if (!parent) {
            return;
          }
          parents.add(parent);
          while (mark.firstChild) {
            parent.insertBefore(mark.firstChild, mark);
          }
          parent.removeChild(mark);
        });
        parents.forEach(function (parent) {
          parent.normalize();
        });
        matches = [];
        activeIndex = -1;
        if (preserveScroll !== false) {
          restoreScroll(x, y);
        }
        return state();
      }

      function shouldSkipNode(node) {
        if (!node.nodeValue || node.nodeValue.length === 0) {
          return true;
        }

        let element = node.parentElement;
        while (element) {
          if (skippedTags.has(element.tagName) || element.classList.contains(hitClass)) {
            return true;
          }
          element = element.parentElement;
        }
        return false;
      }

      function textNodes(root) {
        const nodes = [];
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
          acceptNode: function (node) {
            return shouldSkipNode(node) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
          }
        });
        let current = walker.nextNode();
        while (current) {
          nodes.push(current);
          current = walker.nextNode();
        }
        return nodes;
      }

      function isMarkdownHeadingPrefixQuery(query) {
        return /^#{1,6} $/.test(query);
      }

      function shouldSkipMatch(text, index, query) {
        return isMarkdownHeadingPrefixQuery(query) && index > 0 && text.charAt(index - 1) === '#';
      }

      function highlight(query) {
        const x = window.scrollX;
        const y = window.scrollY;
        clear(false);

        const normalizedQuery = query == null ? '' : String(query);
        if (!normalizedQuery || !/\S/.test(normalizedQuery)) {
          restoreScroll(x, y);
          return state();
        }

        const root = document.getElementById('markdown-body') || document.body;
        const normalizedQueryLower = normalizedQuery.toLocaleLowerCase();
        const queryLength = normalizedQuery.length;

        textNodes(root).forEach(function (node) {
          const text = node.nodeValue;
          const searchableText = text.toLocaleLowerCase();
          let lastIndex = 0;
          let searchIndex = 0;
          let found = false;
          const fragment = document.createDocumentFragment();

          let matchIndex = searchableText.indexOf(normalizedQueryLower, searchIndex);
          while (matchIndex !== -1) {
            if (shouldSkipMatch(text, matchIndex, normalizedQuery)) {
              searchIndex = matchIndex + queryLength;
              matchIndex = searchableText.indexOf(normalizedQueryLower, searchIndex);
              continue;
            }

            if (matchIndex > lastIndex) {
              fragment.appendChild(document.createTextNode(text.slice(lastIndex, matchIndex)));
            }

            const mark = document.createElement('mark');
            mark.className = hitClass;
            mark.textContent = text.slice(matchIndex, matchIndex + queryLength);
            fragment.appendChild(mark);
            matches.push(mark);
            lastIndex = matchIndex + queryLength;
            searchIndex = lastIndex;
            found = true;

            matchIndex = searchableText.indexOf(normalizedQueryLower, searchIndex);
          }

          if (!found) {
            return;
          }

          if (lastIndex < text.length) {
            fragment.appendChild(document.createTextNode(text.slice(lastIndex)));
          }
          node.parentNode.replaceChild(fragment, node);
        });

        activeIndex = -1;
        restoreScroll(x, y);
        return state();
      }

      function setActive(index, shouldScroll) {
        if (matches.length === 0) {
          activeIndex = -1;
          return state();
        }

        if (activeIndex >= 0 && matches[activeIndex]) {
          matches[activeIndex].classList.remove(activeClass);
        }

        activeIndex = index;
        const current = matches[activeIndex];
        current.classList.add(activeClass);
        if (shouldScroll) {
          current.scrollIntoView({ block: 'center', inline: 'nearest' });
        }
        return state();
      }

      function next() {
        if (matches.length === 0) {
          return state();
        }

        const nextIndex = activeIndex < 0 ? 0 : (activeIndex + 1) % matches.length;
        return setActive(nextIndex, true);
      }

      window.miniMDSearch = {
        highlight: highlight,
        next: next,
        clear: clear,
        state: state
      };
    }());
    </script>
    """#
}
