(function () {
    'use strict';

    var modal = document.getElementById('dns-settings-help-modal');
    if (!modal) {
        return;
    }

    var titleEl = document.getElementById('dns-settings-help-title');
    var bodyEl = document.getElementById('dns-settings-help-body');
    var closeBtn = modal.querySelector('.dns-help-modal__close');
    var backdrop = modal.querySelector('.dns-help-modal__backdrop');
    var lastFocus = null;
    var panels = {};

    document.querySelectorAll('[data-dns-help-panel]').forEach(function (panel) {
        panels[panel.getAttribute('data-dns-help-panel')] = panel.innerHTML;
    });

    function trapFocus(event) {
        if (event.key !== 'Tab' || !modal.classList.contains('is-open')) {
            return;
        }

        var focusable = modal.querySelectorAll(
            'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
        );
        if (!focusable.length) {
            return;
        }

        var first = focusable[0];
        var last = focusable[focusable.length - 1];

        if (event.shiftKey && document.activeElement === first) {
            event.preventDefault();
            last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
            event.preventDefault();
            first.focus();
        }
    }

    function openHelp(panelId, trigger) {
        var html = panels[panelId];
        if (!html) {
            return;
        }

        lastFocus = trigger || document.activeElement;
        titleEl.textContent = panelId === 'srv-profiles'
            ? 'SRV profiles (JSON)'
            : 'Primary domains (JSON)';
        bodyEl.innerHTML = html;
        modal.classList.add('is-open');
        modal.setAttribute('aria-hidden', 'false');
        closeBtn.focus();
    }

    function closeHelp() {
        modal.classList.remove('is-open');
        modal.setAttribute('aria-hidden', 'true');
        bodyEl.innerHTML = '';
        if (lastFocus && typeof lastFocus.focus === 'function') {
            lastFocus.focus();
        }
    }

    document.querySelectorAll('[data-dns-help-open]').forEach(function (button) {
        button.addEventListener('click', function () {
            openHelp(button.getAttribute('data-dns-help-open'), button);
        });
    });

    closeBtn.addEventListener('click', closeHelp);
    backdrop.addEventListener('click', closeHelp);

    document.addEventListener('keydown', function (event) {
        if (event.key === 'Escape' && modal.classList.contains('is-open')) {
            event.preventDefault();
            closeHelp();
        }
        trapFocus(event);
    });
})();
