/* Append streamed log text without HTML interpretation or page replacement. */
(function() {
    'use strict';
    var panels = new Set();
    var limit = 2 * 1024 * 1024;
    function attach(panel) {
        if (panels.has(panel)) return;
        panels.add(panel);
        var output = panel.querySelector('[data-log-output]');
        var status = panel.querySelector('[data-log-status]');
        var follow = panel.querySelector('[data-log-follow]');
        var notice = panel.querySelector('[data-log-notice]');
        var step = panel.querySelector('[data-log-step]');
        var source, cursor = '', done = false, text = '';
        var subject = new URL(panel.dataset.logUrl, location.href).searchParams.has('step') ? 'Step' : 'Build';
        function visible() {
            var tab = panel.closest('.tab-pane');
            return panel.isConnected && !document.hidden && (!tab || tab.classList.contains('active'));
        }
        function append(chunk) {
            // Terminal colour/control sequences are plain log decoration here.
            chunk = chunk.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '');
            text += chunk;
            if (text.length > limit) {
                text = text.slice(-limit);
                var line = text.indexOf('\n');
                if (line >= 0) text = text.slice(line + 1);
                output.textContent = text;
                notice.textContent = 'Showing the latest output. The raw log contains the full output.';
            } else if (output.lastChild) output.lastChild.appendData(chunk);
            else output.appendChild(document.createTextNode(chunk));
            if (follow.checked) output.scrollTop = output.scrollHeight;
        }
        function connect() {
            if (!visible() || source || done) return;
            var url = new URL(panel.dataset.logUrl, location.href);
            if (cursor) url.searchParams.set('cursor', cursor);
            source = new EventSource(url);
            source.onopen = function() { status.textContent = 'Connected — waiting for output'; };
            source.onerror = function() { status.textContent = 'Connection interrupted — reconnecting...'; };
            source.addEventListener('state', function(event) {
                var data = JSON.parse(event.data);
                status.textContent = data.status === 'queued' ? 'Queued — waiting for a build step' :
                    data.finished ? 'Receiving completed log' : 'Building — live output';
                panel.querySelector('[data-log-raw]').href = panel.dataset.buildUrl +
                    (data.step === null ? '/log/raw' : '/nixlog/' + data.step + '/raw');
                step.textContent = (data.step === null ? '' : 'Step ' + data.step + ': ') + data.drvpath;
            });
            source.addEventListener('reset', function() {
                text = ''; cursor = ''; output.textContent = ''; notice.textContent = '';
            });
            source.addEventListener('log', function(event) {
                var data = JSON.parse(event.data);
                cursor = event.lastEventId;
                if (data.truncated) notice.textContent = 'Showing the latest output. The raw log contains the full output.';
                append(data.text);
            });
            source.addEventListener('done', function(event) {
                var data = JSON.parse(event.data);
                status.textContent = !data.available ? subject + ' finished — no log is available' :
                    data.buildstatus === 0 ? subject + ' succeeded — log complete' : subject + ' finished — log complete';
                done = true;
                source.close(); source = null;
                document.dispatchEvent(new Event('hydra:change'));
            });
        }
        function update() {
            if (done && panel.dataset.logFinished === '0') {
                done = false; cursor = ''; text = ''; output.textContent = '';
            }
            if (!visible() && source) { source.close(); source = null; }
            connect();
        }
        output.addEventListener('scroll', function() {
            if (output.scrollHeight - output.clientHeight - output.scrollTop > 40) follow.checked = false;
        });
        follow.addEventListener('change', function() {
            if (follow.checked) output.scrollTop = output.scrollHeight;
        });
        document.addEventListener('visibilitychange', update);
        document.addEventListener('hydra:updated', update);
        $(document).on('shown.bs.tab hidden.bs.tab', update);
        connect();
    }
    function discover() {
        document.querySelectorAll('[data-live-log]').forEach(attach);
    }
    $(discover);
    document.addEventListener('hydra:updated', discover);
})();
