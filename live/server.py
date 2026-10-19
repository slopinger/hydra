"""Async event and log streams for Hydra's server-rendered web interface."""
import asyncio
import bz2
import codecs
import contextlib
import json
import logging
import os
from pathlib import Path
import re
import time

import aiohttp
from aiohttp import web
import asyncpg
import zstandard

CHANNELS = (
    'build_started', 'build_finished', 'step_started', 'step_finished',
    'builds_added', 'build_queued', 'builds_deleted', 'builds_restarted',
    'builds_cancelled', 'builds_bumped', 'cached_build_finished',
    'eval_started', 'eval_added', 'eval_failed', 'eval_cached',
    'jobsets_added', 'jobsets_deleted', 'jobset_scheduling_changed', 'status_dumped',
)
HEADERS = {'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store',
           'X-Accel-Buffering': 'no'}


async def send(response, event, data, cursor=None):
    message = f'event: {event}\ndata: {json.dumps(data, ensure_ascii=True)}\n'
    if cursor is not None:
        message += f'id: {cursor}\n'
    # A slow/disconnected reader must not retain a task and DB resources forever.
    await asyncio.wait_for(response.write((message + '\n').encode()), 15)


class LogReader:
    """Hold the open file through compression/unlink; decode split UTF-8 safely."""
    def __init__(self, root, drvpath, offset=None):
        base = Path(drvpath).name
        if not re.fullmatch(r'[0-9a-z]{32}-[A-Za-z0-9+._?=\-]+\.drv', base):
            raise ValueError('Invalid derivation path')
        self.path = Path(root) / base[:2] / base[2:]
        self.offset = offset
        self.position = 0
        self.handle = None
        self.decoder = codecs.getincrementaldecoder('utf-8')('replace')
        self.truncated = False
        self.raw = False
        self.rewound = False

    def open(self):
        if self.path.is_file():
            self.handle = self.path.open('rb')
            self.raw = True
            size = os.fstat(self.handle.fileno()).st_size
            offset = self.offset
            if offset is None and size > 128 * 1024:
                self.handle.seek(size - 128 * 1024)
                self.handle.readline()
                offset = self.handle.tell()
                self.truncated = True
            self.rewound = offset is not None and offset > size
            self.position = 0 if self.rewound else max(0, offset or 0)
            self.handle.seek(self.position)
        elif self.path.with_suffix(self.path.suffix + '.bz2').is_file():
            self.handle = bz2.open(str(self.path) + '.bz2', 'rb')
        elif self.path.with_suffix(self.path.suffix + '.zst').is_file():
            self.handle = zstandard.open(str(self.path) + '.zst', 'rb')
        else:
            return False
        if not self.raw and self.offset:
            # Compressed logs support the same uncompressed byte cursor.
            self.handle.seek(self.offset)
            self.position = self.offset
        return True

    def read(self):
        if self.handle is None and not self.open():
            return '', False, False
        reset = self.rewound
        self.rewound = False
        # Only raw logs grow or get truncated. Compressed logs are immutable.
        if self.raw:
            if os.fstat(self.handle.fileno()).st_size < self.position:
                self.handle.seek(0)
                self.position = 0
                self.decoder.reset()
                reset = True
        chunk = self.handle.read(64 * 1024)
        self.position += len(chunk)
        return self.decoder.decode(chunk), bool(chunk), reset

    @property
    def committed(self):
        return self.position - len(self.decoder.getstate()[0])

    def close(self):
        if self.handle:
            self.handle.close()


class Streams:
    def __init__(self, database, logs, authorize_url):
        self.database = database
        self.logs = logs
        self.authorize_url = authorize_url
        self.subscribers = set()
        self.pool = None
        self.http = None
        self.listener = None

    async def start(self, app):
        self.pool = await asyncpg.create_pool(self.database, min_size=1, max_size=4,
                                             command_timeout=10)
        self.http = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=10))
        self.listener = asyncio.create_task(self.listen())

    async def stop(self, app):
        self.listener.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await self.listener
        await self.http.close()
        await self.pool.close()

    def changed(self, *args):
        for queue in self.subscribers:
            if queue.empty():
                queue.put_nowait(True)

    async def listen(self):
        while True:
            connection = None
            try:
                connection = await asyncpg.connect(self.database, command_timeout=10)
                for channel in CHANNELS:
                    await connection.add_listener(channel, self.changed)
                self.changed()  # Reconcile changes missed while disconnected.
                while not connection.is_closed():
                    await asyncio.sleep(5)
                    await connection.execute('SELECT 1')
            except (OSError, asyncpg.PostgresError, asyncpg.InterfaceError, asyncio.TimeoutError):
                logging.exception('Reconnecting Hydra event listener')
                await asyncio.sleep(2)
            finally:
                if connection is not None:
                    await connection.close()

    async def authorize(self, request):
        # Let Catalyst apply its actual private-instance/session rules. No
        # credentials, tokens or session database are duplicated in this service.
        headers = {'Cookie': request.headers.get('Cookie', ''), 'Accept': 'application/json',
                   'X-Forwarded-For': request.headers.get('X-Forwarded-For', request.remote or '')}
        try:
            async with self.http.get(self.authorize_url, headers=headers,
                                     allow_redirects=False) as response:
                if response.status != 204:
                    raise web.HTTPForbidden(text='Sign in to view live updates.')
        except (aiohttp.ClientError, asyncio.TimeoutError):
            raise web.HTTPServiceUnavailable(text='Hydra authentication unavailable.')

    async def events(self, request):
        await self.authorize(request)
        response = web.StreamResponse(headers=HEADERS)
        queue = asyncio.Queue(maxsize=1)
        self.subscribers.add(queue)
        try:
            await response.prepare(request)
            await send(response, 'change', {})
            last_auth = time.monotonic()
            while True:
                try:
                    await asyncio.wait_for(queue.get(), 15)
                    await asyncio.sleep(.15)  # Coalesce a burst of build completions.
                    await send(response, 'change', {})
                except asyncio.TimeoutError:
                    if time.monotonic() - last_auth > 60:
                        await self.authorize(request)
                        last_auth = time.monotonic()
                    await response.write(b': keepalive\n\n')
        except (ConnectionError, asyncio.TimeoutError, web.HTTPException):
            pass
        finally:
            self.subscribers.discard(queue)
        return response

    async def state(self, build_id, step_number):
        build = await self.pool.fetchrow(
            'SELECT id, finished, buildstatus, drvpath FROM builds WHERE id = $1', build_id)
        if build is None:
            raise web.HTTPNotFound(text='Build does not exist.')
        steps = await self.pool.fetch(
            'SELECT stepnr, drvpath, busy, status, starttime FROM buildsteps '
            'WHERE build = $1 ORDER BY (busy != 0) DESC, type ASC, stepnr DESC', build_id)
        if step_number is not None:
            step = next((s for s in steps if s['stepnr'] == step_number), None)
            if step is None:
                raise web.HTTPNotFound(text='Build step does not exist.')
        else:
            # Follow running dependencies, then the build's own log (or the
            # failed dependency when its own derivation never ran).
            step = next((s for s in steps if s['busy'] and s['drvpath']), None)
            step = step or next((s for s in steps if s['drvpath'] == build['drvpath']), None)
            step = step or next((s for s in steps if s['status'] not in (None, 0)), None)
        busy = any(s['busy'] for s in steps)
        finished = bool(build['finished']) if step_number is None else not bool(step['busy'])
        drvpath = step['drvpath'] if step else build['drvpath']
        generation = f"{step['stepnr']}:{step['starttime'] or 0}" if step else 'build'
        return {'finished': finished, 'buildstatus': step['status'] if step_number is not None else build['buildstatus'],
                'status': 'finished' if finished else 'building' if busy else 'queued',
                'step': step['stepnr'] if step else None, 'drvpath': drvpath,
                'generation': generation}

    async def log(self, request):
        await self.authorize(request)
        build_id = int(request.match_info['build'])
        if build_id > 2**31 - 1:
            raise web.HTTPNotFound(text='Build does not exist.')
        raw_step = request.query.get('step')
        if raw_step is not None and not raw_step.isdecimal():
            raise web.HTTPBadRequest(text='Invalid step.')
        step_number = int(raw_step) if raw_step is not None else None
        if step_number is not None and step_number > 2**31 - 1:
            raise web.HTTPBadRequest(text='Invalid step.')
        state = await self.state(build_id, step_number)
        cursor = request.headers.get('Last-Event-ID', request.query.get('cursor', ''))
        if len(cursor) > 256:
            raise web.HTTPBadRequest(text='Invalid log cursor.')
        response = web.StreamResponse(headers=HEADERS)
        reader = None
        generation = None
        last_state = None
        last_auth = time.monotonic()
        last_ping = last_auth
        last_state_check = last_auth
        try:
            await response.prepare(request)
            while True:
                if state != last_state:
                    await send(response, 'state', state)
                    last_state = state
                key = state['generation'] + ':' + Path(state['drvpath']).name
                if key != generation:
                    if reader:
                        reader.close()
                    resume = re.fullmatch(re.escape(key) + r':(\d+)', cursor)
                    reader = LogReader(self.logs, state['drvpath'], min(int(resume[1]), 2**63 - 1) if resume else None)
                    generation = key
                    if not resume:
                        await send(response, 'reset', {'step': state['step'], 'drvpath': state['drvpath']})
                while True:
                    text, more, reset = await asyncio.to_thread(reader.read)
                    if reset:
                        await send(response, 'reset', {'step': state['step'], 'drvpath': state['drvpath']})
                    if text:
                        await send(response, 'log', {'text': text, 'truncated': reader.truncated},
                                   f'{key}:{reader.committed}')
                    if not more:
                        break
                if state['finished']:
                    remaining = reader.decoder.decode(b'', final=True)
                    if remaining:
                        await send(response, 'log', {'text': remaining}, f'{key}:{reader.position}')
                    await send(response, 'done', {'available': reader.handle is not None, **state})
                    break
                await asyncio.sleep(.3)
                if time.monotonic() - last_auth > 60:
                    await self.authorize(request)
                    last_auth = time.monotonic()
                if time.monotonic() - last_ping > 15:
                    await response.write(b': keepalive\n\n')
                    last_ping = time.monotonic()
                if time.monotonic() - last_state_check > 1:
                    state = await self.state(build_id, step_number)
                    last_state_check = time.monotonic()
        except (ConnectionError, asyncio.TimeoutError, web.HTTPException):
            pass
        finally:
            if reader:
                reader.close()
        return response


def create_app(streams):
    active = 0

    @web.middleware
    async def limit_connections(request, handler):
        nonlocal active
        if active >= 256:
            raise web.HTTPServiceUnavailable(text='Too many live connections.')
        active += 1
        try:
            return await handler(request)
        finally:
            active -= 1

    app = web.Application(middlewares=[limit_connections])
    app.router.add_get('/_live/events', streams.events)
    app.router.add_get(r'/_live/log/{build:\d+}', streams.log)
    app.on_startup.append(streams.start)
    app.on_cleanup.append(streams.stop)
    return app


def main():
    logging.basicConfig(level=logging.INFO)
    streams = Streams(os.environ['HYDRA_LIVE_DATABASE'],
                      os.environ.get('HYDRA_LIVE_LOGS', '/var/lib/hydra/build-logs'),
                      os.environ.get('HYDRA_LIVE_AUTHORIZE', 'http://127.0.0.1:3000/_live/authorize'))
    web.run_app(create_app(streams), host='127.0.0.1',
                port=int(os.environ.get('HYDRA_LIVE_PORT', '3002')), handler_cancellation=True)


if __name__ == '__main__':
    main()
