(function () {
  var root = document.documentElement;
  var toggle = document.querySelector('.theme-toggle');
  var media = window.matchMedia('(prefers-color-scheme: dark)');

  function currentTheme() {
    return root.dataset.theme || (media.matches ? 'dark' : 'light');
  }

  function applyTheme(theme, save) {
    root.dataset.theme = theme;
    if (save) {
      localStorage.setItem('theme', theme);
    }

    if (!toggle) {
      return;
    }

    var isDark = theme === 'dark';
    toggle.setAttribute('aria-pressed', String(isDark));
    toggle.setAttribute('aria-label', isDark ? 'Switch to light mode' : 'Switch to dark mode');
    toggle.dataset.themeState = isDark ? 'dark' : 'light';
  }

  applyTheme(currentTheme(), false);

  if (toggle) {
    toggle.addEventListener('click', function () {
      applyTheme(currentTheme() === 'dark' ? 'light' : 'dark', true);
    });
  }

  media.addEventListener('change', function (event) {
    if (localStorage.getItem('theme')) {
      return;
    }
    applyTheme(event.matches ? 'dark' : 'light', false);
  });
}());
