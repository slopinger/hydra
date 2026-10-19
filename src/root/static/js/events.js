/* One event stream per page. Catalyst still renders the standard HTML. */
(function() {
    'use strict';
    var meta = document.querySelector('meta[name="hydra-live-events"]');
    if (!meta || !window.EventSource) return;
    var source, retry, retryDelay = 1000;
    function connection(connected) {
        window.hydraStreamConnected = connected;
        document.dispatchEvent(new CustomEvent('hydra:connection', { detail: connected }));
    }
    function connect() {
        if (source || document.hidden) return;
        source = new EventSource(meta.content);
        var current = source;
        source.onopen = function() { retryDelay = 1000; connection(true); };
        source.onerror = function() {
            if (source !== current) return;
            source.close(); source = null;
            connection(false);
            clearTimeout(retry);
            retry = setTimeout(connect, retryDelay);
            retryDelay = Math.min(retryDelay * 2, 30000);
        };
        source.addEventListener('change', function() {
            document.dispatchEvent(new Event('hydra:change'));
        });
    }
    document.addEventListener('visibilitychange', function() {
        clearTimeout(retry);
        if (document.hidden && source) {
            source.close();
            source = null;
            connection(false);
        } else connect();
    });
    connect();
})();
