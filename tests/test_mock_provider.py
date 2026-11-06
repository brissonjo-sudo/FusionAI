"""Verify fixture infrastructure only. These tests do NOT run Delphi code."""
import json
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from mock_provider import make_server


class FixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = make_server(0)
        cls.worker = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.worker.start()
        cls.url = f'http://127.0.0.1:{cls.server.server_port}'

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.worker.join()
        cls.server.server_close()

    def post(self, path, body):
        req = Request(self.url + path, data=json.dumps(body).encode(),
                      headers={'Content-Type': 'application/json'})
        with urlopen(req, timeout=2) as response:
            return json.load(response)

    def setUp(self):
        self.server.scenario = 'success'

    def test_all_provider_shapes(self):
        self.assertIn('choices', self.post('/v1/chat/completions', {'model': 'o3'}))
        self.assertEqual(len(self.post('/v1/messages', {})['content']), 3)
        self.assertIn('candidates', self.post('/v1beta/models/test:generateContent', {}))
        self.assertTrue(self.post('/api/generate', {})['done'])

    def test_reject_unsupported_sampling(self):
        with self.assertRaises(HTTPError) as caught:
            self.post('/v1/messages', {'temperature': 0})
        self.assertEqual(caught.exception.code, 400)
        caught.exception.close()

    def test_truncation(self):
        self.server.scenario = 'truncated'
        self.assertEqual(self.post('/v1/messages', {})['stop_reason'], 'max_tokens')

    def test_truncated_without_text(self):
        self.server.scenario = 'truncated_empty'
        choice = self.post('/v1/chat/completions', {'model': 'o3'})['choices'][0]
        self.assertEqual((choice['message']['content'], choice['finish_reason']), ('', 'length'))
        generated = self.post('/api/generate', {})
        self.assertEqual((generated['response'], generated['done_reason']), ('', 'length'))

    def test_http_error(self):
        self.server.scenario = 'error429'
        with self.assertRaises(HTTPError) as caught:
            self.post('/api/generate', {})
        self.assertEqual(caught.exception.code, 429)
        self.assertIn('Fixture rate limit', caught.exception.read().decode())
        caught.exception.close()

    def test_model_catalogs(self):
        for path, key in [('/v1/models', 'data'), ('/v1beta/models', 'models'), ('/api/tags', 'models')]:
            with urlopen(self.url + path, timeout=2) as response:
                self.assertTrue(json.load(response)[key])


if __name__ == '__main__':
    unittest.main()
