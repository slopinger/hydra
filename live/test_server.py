import asyncio
import bz2
import tempfile
import unittest
from pathlib import Path

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer
import zstandard

from server import LogReader, Streams, create_app

DRV = '/nix/store/' + 'a' * 32 + '-example.drv'


def log_path(root):
    path = Path(root) / 'aa' / (Path(DRV).name[2:])
    path.parent.mkdir(exist_ok=True)
    return path


class ReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = log_path(self.temp.name)

    def reader(self, offset=None):
        reader = LogReader(self.temp.name, DRV, offset)
        self.addCleanup(reader.close)
        return reader

    def test_append_split_unicode_and_resume(self):
        self.path.write_bytes(b'first\n\xe2')
        reader = self.reader()
        self.assertEqual(reader.read()[0], 'first\n')
        self.assertEqual(reader.committed, 6)
        with self.path.open('ab') as output:
            output.write(b'\x82\xac\n')
        self.assertEqual(reader.read()[0], '\u20ac\n')
        resumed = self.reader(6)
        self.assertEqual(resumed.read()[0], '\u20ac\n')

    def test_truncation_and_file_unlink(self):
        self.path.write_text('old log\n')
        reader = self.reader()
        reader.read()
        self.path.write_text('new\n')
        text, more, reset = reader.read()
        self.assertEqual((text, reset), ('new\n', True))
        self.path.unlink()
        self.assertEqual(reader.read()[0], '')  # Open descriptor survives compression.

    def test_large_initial_tail_and_invalid_cursor(self):
        self.path.write_bytes(b'line\n' * 40000)
        reader = self.reader()
        text, _, _ = reader.read()
        self.assertTrue(reader.truncated)
        self.assertLessEqual(len(text), 65536)
        restarted = self.reader(9999999)
        self.assertTrue(restarted.read()[2])

    def test_archives_and_resume(self):
        text = 'some output\n\u20ac\n'
        for suffix, compress in [('.bz2', bz2.compress), ('.zst', zstandard.compress)]:
            with self.subTest(suffix=suffix):
                path = Path(str(self.path) + suffix)
                path.write_bytes(compress(text.encode()))
                self.assertEqual(self.reader().read()[0], text)
                self.assertEqual(self.reader(5).read()[0], text[5:])
                path.unlink()

    def test_wait_for_log_and_reject_paths(self):
        reader = self.reader()
        self.assertEqual(reader.read(), ('', False, False))
        self.path.write_text('started\n')
        self.assertEqual(reader.read()[0], 'started\n')
        with self.assertRaises(ValueError):
            LogReader(self.temp.name, '/etc/passwd')


class FakePool:
    def __init__(self):
        self.build = {'id': 1, 'finished': 0, 'buildstatus': None, 'drvpath': DRV}
        self.steps = []

    async def fetchrow(self, query, build_id):
        return self.build if build_id == 1 else None

    async def fetch(self, query, build_id):
        return self.steps


class TestStreams(Streams):
    async def start(self, app):
        self.pool = FakePool()
        self.http = self.http_session()

    async def stop(self, app):
        await self.http.close()


async def event(response, kind):
    async def read():
        while True:
            line = await response.content.readline()
            if not line:
                raise AssertionError('Stream ended before ' + kind)
            if line.decode().strip() == 'event: ' + kind:
                import json
                data = await response.content.readline()
                return json.loads(data.decode()[6:])
    return await asyncio.wait_for(read(), 5)


class StreamTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = log_path(self.temp.name)
        auth = web.Application()

        async def authorize(request):
            response = web.Response(status=204 if request.cookies.get('session') == 'allowed' else 403)
            if response.status == 204:
                response.set_cookie('session', 'allowed')
            return response

        auth.router.add_get('/authorize', authorize)
        self.auth = TestServer(auth)
        await self.auth.start_server()
        self.streams = TestStreams('', self.temp.name, str(self.auth.make_url('/authorize').with_host('localhost')))
        self.client = TestClient(TestServer(create_app(self.streams), handler_cancellation=True))
        await self.client.start_server()
        self.headers = {'Cookie': 'session=allowed'}

    async def asyncTearDown(self):
        await self.client.close()
        await self.auth.close()
        self.temp.cleanup()

    async def test_authorization_and_invalid_requests(self):
        denied = await self.client.get('/_live/events')
        self.assertEqual(denied.status, 403)
        for path, status in [('/_live/log/2', 404), ('/_live/log/1?step=no', 400),
                             ('/_live/log/1?step=9', 404)]:
            response = await self.client.get(path, headers=self.headers)
            self.assertEqual(response.status, status)

    async def test_authorization_is_not_reused_between_clients(self):
        response = await self.client.get('/_live/events', headers=self.headers)
        await event(response, 'change')
        response.close()
        anonymous = await self.client.get('/_live/events')
        self.assertEqual(anonymous.status, 403)

    async def test_notifications_are_pushed_on_one_connection(self):
        response = await self.client.get('/_live/events', headers=self.headers)
        self.assertEqual(response.headers['Content-Type'], 'text/event-stream')
        await event(response, 'change')
        self.streams.changed(None, None, 'build_started', '1')
        await event(response, 'change')
        response.close()

    async def test_queued_running_log_append_and_completion(self):
        response = await self.client.get('/_live/log/1', headers=self.headers)
        self.assertEqual((await event(response, 'state'))['status'], 'queued')
        self.streams.pool.steps = [{'stepnr': 1, 'busy': 1, 'status': None,
                                   'starttime': 100, 'drvpath': DRV}]
        self.path.write_text('first\n')
        self.assertEqual((await event(response, 'log'))['text'], 'first\n')
        with self.path.open('a') as output:
            output.write('<script>literal output</script>\n')
        self.assertEqual((await event(response, 'log'))['text'], '<script>literal output</script>\n')
        self.streams.pool.build['finished'] = 1
        self.streams.pool.build['buildstatus'] = 0
        self.streams.pool.steps[0]['busy'] = 0
        done = await event(response, 'done')
        self.assertTrue(done['available'])
        self.assertEqual(done['buildstatus'], 0)

    async def test_reconnect_resumes_and_finished_archive(self):
        self.path.write_bytes(b'first\nsecond\n')
        self.streams.pool.build['finished'] = 1
        self.streams.pool.build['buildstatus'] = 1
        self.streams.pool.steps = [{'stepnr': 1, 'busy': 0, 'status': 1,
                                   'starttime': 100, 'drvpath': DRV}]
        cursor = '1:100:' + Path(DRV).name + ':6'
        response = await self.client.get('/_live/log/1', headers={
            **self.headers, 'Last-Event-ID': cursor})
        self.assertEqual((await event(response, 'log'))['text'], 'second\n')
        self.assertEqual((await event(response, 'done'))['buildstatus'], 1)
        self.path.rename(str(self.path) + '.old')
        Path(str(self.path) + '.bz2').write_bytes(bz2.compress(b'finished output\n'))
        response = await self.client.get('/_live/log/1', headers=self.headers)
        self.assertEqual((await event(response, 'log'))['text'], 'finished output\n')
        self.assertTrue((await event(response, 'done'))['available'])

    async def test_completion_without_log(self):
        self.streams.pool.build['finished'] = 1
        response = await self.client.get('/_live/log/1', headers=self.headers)
        self.assertFalse((await event(response, 'done'))['available'])


if __name__ == '__main__':
    unittest.main()
