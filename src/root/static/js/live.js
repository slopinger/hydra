/* Refresh the existing server-rendered interface, without navigating or running
 * page scripts again. Forms are outside refresh regions; lazy tabs retain their
 * loaded DOM (including charts and dependency trees). */
$(function() {
    'use strict';
    var page = document.getElementById('hydra-content');
    var pageType = page.getAttribute('data-live-page');
    var selector = '[data-live-region]';
    var snapshots = new Map();
    var delay = 5000;
    var timer;
    var pending = false;

    function regions(root) {
        var parts = Array.from(root.querySelectorAll(selector));
        return parts.length ? parts : [root];
    }

    function clean(part) {
        part.querySelectorAll('script').forEach(function(script) { script.remove(); });
        return part;
    }

    regions(page).forEach(function(part) {
        snapshots.set(part.id, clean(part.cloneNode(true)).innerHTML);
    });

    function schedule() {
        clearTimeout(timer);
        if (!document.hidden) timer = setTimeout(refresh, delay);
    }

    function refresh() {
        if (pending || document.hidden) return;
        // Avoid interrupting a menu, modal, text selection, or form interaction.
        if ($('.modal.show, .dropdown-menu.show, .popover').length ||
            $(document.activeElement).is('input, textarea, select, [contenteditable]') ||
            !window.getSelection().isCollapsed) {
            schedule();
            return;
        }
        pending = true;
        var uri = window.location.href.split('#')[0];
        $.ajax({
            url: uri,
            dataType: 'html',
            headers: { Accept: 'text/html' },
            cache: false,
            timeout: 15000
        }).then(function(html) {
            if (document.hidden || window.location.href.split('#')[0] !== uri) return;
            // Interaction can begin while the request is in flight.
            if ($('.modal.show, .dropdown-menu.show, .popover').length ||
                $(document.activeElement).is('input, textarea, select, [contenteditable]') ||
                !window.getSelection().isCollapsed) return;
            var doc = new DOMParser().parseFromString(html, 'text/html');
            var fresh = doc.getElementById('hydra-content');
            if (!fresh || fresh.getAttribute('data-live-page') !== pageType) return;
            var activeTab = $('#live-tabs a.active').attr('href');
            var filters = {};
            $('#show-hidden, #show-disabled').each(function() {
                filters[this.id] = $(this).hasClass('active');
            });
            var scrollX = window.scrollX, scrollY = window.scrollY;
            regions(fresh).forEach(function(part) {
                clean(part);
                var markup = part.innerHTML;
                var current = document.getElementById(part.id);
                if (!current || snapshots.get(part.id) === markup) return;
                // Preserve chart zoom, expanded trees and already loaded tabs.
                part.querySelectorAll('[data-tab-uri]').forEach(function(tab) {
                    var old = document.getElementById(tab.id);
                    if (old && old.getAttribute('data-tab-uri') === tab.getAttribute('data-tab-uri')) {
                        tab.replaceWith(old);
                    } else {
                        delete tabsLoaded['#' + tab.id];
                    }
                });
                $(current).find('.hydra-popover').popover('dispose');
                $(current).empty().append(Array.from(part.childNodes));
                $(current).find('.hydra-popover').popover({});
                snapshots.set(part.id, markup);
            });
            // Restore the selected tab, falling back when it has disappeared
            // (for example when the last queued evaluation job finishes).
            var links = $('#live-tabs .nav-item:not(.dropdown) a');
            if (links.length) {
                links.removeClass('active');
                $(page).find('.tab-pane').removeClass('active show');
                var selected = links.filter(function() { return $(this).attr('href') === activeTab; });
                (selected.length ? selected : links.first()).tab('show');
            }
            Object.keys(filters).forEach(function(id) {
                $(document.getElementById(id)).toggleClass('active', filters[id]);
            });
            if (typeof window.showProjects === 'function') window.showProjects();
            if (typeof window.showJobsets === 'function') window.showJobsets();
            // Newly inserted absolute timestamps use the same local timezone.
            $(page).find('time.date.is-absolute:not(.is-local)').each(function() {
                var local = moment($(this).data('timestamp'), '%X');
                $(this).attr('title', 'UTC: ' + local.clone().utc().format('YYYY-MM-DD HH:mm:ss'))
                    .text(local.format('YYYY-MM-DD HH:mm:ss')).addClass('is-local');
            });
            window.scrollTo(scrollX, scrollY);
            delay = 5000;
            // Job matrices are lazy-loaded, with their own filter form. Update
            // only their results, leaving the filter and its handlers intact.
            var tab = $(page).find('.tab-pane.active[data-tab-uri]');
            if (tab.attr('id') === 'tabs-jobs' || tab.attr('id') === 'tabs-channels') {
                var query = tab.find('form').serialize();
                if (tab.find('#active-toggle').hasClass('active')) query += '&showInactive=1';
                return $.ajax({
                    url: tab.attr('data-tab-uri'), data: query, dataType: 'html',
                    headers: { Accept: 'text/html' }, timeout: 15000, cache: false
                }).then(function(response) {
                    if (!tab.hasClass('active') || document.hidden ||
                        $(document.activeElement).is('input, textarea, select') ||
                        !window.getSelection().isCollapsed) return;
                    var freshTab = new DOMParser().parseFromString(response, 'text/html');
                    var result = freshTab.getElementById('live-job-results');
                    var target = tab.find('#live-job-results')[0];
                    if (result && target) {
                        $(target).empty().append(Array.from(clean(result).childNodes));
                    } else if (tab.attr('id') === 'tabs-channels') {
                        tab.empty().append(Array.from(clean(freshTab.body).childNodes));
                    }
                });
            }
        }).fail(function() {
            delay = Math.min(delay * 2, 60000);
        }).always(function() {
            pending = false;
            schedule();
        });
    }

    document.addEventListener('visibilitychange', function() {
        clearTimeout(timer);
        if (!document.hidden) refresh();
    });
    schedule();
});
