"""Local HTTP fixtures for manual IDE tests; never calls a real provider."""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Do not log prompts or credentials.

    def reply(self, status, value):
        body = json.dumps(value).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path.endswith('/tags'):
            result = {'models': [{'model': 'test-model', 'name': 'test-model'}]}
        elif self.path.startswith('/v1beta/'):
            result = {'models': [{'name': 'models/test-model', 'displayName': 'Test',
                                  'supportedGenerationMethods': ['generateContent']}]}
        else:
            result = {'data': [{'id': 'gpt-4o-mini', 'display_name': 'Test'}]}
        self.reply(200, result)

    def do_POST(self):
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 2_000_000:
                raise ValueError('invalid request size')
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError('object required')
        except (ValueError, json.JSONDecodeError) as exc:
            self.reply(400, {'error': {'message': str(exc)}})
            return
        scenario = self.server.scenario
        if scenario == 'slow':
            time.sleep(self.server.delay)
        if scenario == 'error429':
            self.reply(429, {'error': {'message': 'Fixture rate limit exceeded'}})
            return
        # truncated_empty: the whole output budget was spent (e.g. on reasoning) before any text.
        text = '' if scenario in ('empty', 'truncated_empty') else '} WriteLn(\'fixture\'); {$IFDEF X}\nsecond line'
        truncated = scenario in ('truncated', 'truncated_empty')
        if self.path.endswith('/chat/completions'):
            classic = body.get('model', '').startswith(('gpt-4', 'gpt-3.5', 'chatgpt-4o'))
            if not classic and any(k in body for k in ('temperature', 'top_p', 'max_tokens')):
                self.reply(400, {'error': {'message': 'Unsupported reasoning parameter'}})
                return
            result = {'choices': [{'message': {'role': 'assistant', 'content': text},
                                   'finish_reason': 'length' if truncated else 'stop'}]}
        elif self.path.endswith('/messages'):
            if any(k in body for k in ('temperature', 'top_p')):
                self.reply(400, {'error': {'message': 'Sampling fields are unsupported'}})
                return
            result = {'content': [{'type': 'thinking', 'thinking': 'ignore'},
                                  {'type': 'text', 'text': text},
                                  {'type': 'text', 'text': ' tail' if text else ''}],
                      'stop_reason': 'max_tokens' if truncated else 'end_turn'}
        elif ':generateContent' in self.path:
            result = {'candidates': [{'content': {'parts': [{'text': text}]},
                                      'finishReason': 'MAX_TOKENS' if truncated else 'STOP'}]}
        elif self.path.endswith('/generate'):
            result = {'response': text, 'done': True,
                      'done_reason': 'length' if truncated else 'stop'}
        else:
            self.reply(404, {'error': {'message': 'Unknown fixture route'}})
            return
        self.reply(200, result)


def make_server(port=8765, scenario='success', delay=10):
    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    server.daemon_threads = True
    server.scenario, server.delay = scenario, delay
    return server


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--scenario', choices=['success', 'empty', 'truncated', 'truncated_empty', 'error429', 'slow'], default='success')
    parser.add_argument('--delay', type=float, default=10)
    args = parser.parse_args()
    with make_server(args.port, args.scenario, args.delay) as server:
        print(f'Fixture: http://127.0.0.1:{server.server_port} ({args.scenario}); Ctrl+C to stop')
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
