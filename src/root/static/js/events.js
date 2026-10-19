/* One event stream per page. Catalyst still renders the standard HTML. */
(function() {
    'use strict';
    var meta = document.querySelector('meta[name="hydra-live-events"]');
    if (!meta || !window.EventSource) return;
    var source;
    function connection(connected) {
        window.hydraStreamConnected = connected;
        document.dispatchEvent(new CustomEvent('hydra:connection', { detail: connected }));
    }
    function connect() {
        if (source || document.hidden) return;
        source = new EventSource(meta.content);
        source.onopen = function() { connection(true); };
        source.onerror = function() { connection(false); };
        source.addEventListener('change', function() {
            document.dispatchEvent(new Event('hydra:change'));
        });
    }
    document.addEventListener('visibilitychange', function() {
        if (document.hidden && source) {
            source.close();
            source = null;
            connection(false);
        } else connect();
    });
    connect();
})();
