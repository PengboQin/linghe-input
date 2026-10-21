"""Loopback-only XCTest fixture exposes PUBLIC invitation/code/status, no secrets."""
import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--status',type=Path,required=True);parser.add_argument('--ready',type=Path,required=True);args=parser.parse_args()
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != '/status': self.send_error(404);return
            if not args.status.exists():self.send_error(404);return
            data=args.status.read_bytes()
            if len(data)>16384:self.send_error(500);return
            json.loads(data)
            self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
        def log_message(self,*args):pass
    server=HTTPServer(('127.0.0.1',0),Handler)
    args.ready.write_text(json.dumps({'port':server.server_port}))
    server.serve_forever()
if __name__=='__main__':main()
