"""LAN media server for the Chromecast demo screen.

Serves a directory with CORS headers AND HTTP Range support. Both matter
for Cast receivers: CORS is required for sidecar caption tracks, and Range
is required for SEEK — without it the receiver restarts the download from
byte 0 and playback jumps back to the start.

Usage:
    python3 cast_media_server.py <directory> [port]

Then point CastScreen.mediaUrl/captionsUrl at http://<your-lan-ip>:<port>/.
"""

import http.server
import functools
import os
import re
import sys


class RangeCORSHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Accept-Ranges', 'bytes')
        super().end_headers()

    def send_head(self):
        self.range = None
        path = self.translate_path(self.path)
        range_header = self.headers.get('Range')
        if os.path.isdir(path) or not range_header:
            return super().send_head()
        match = re.match(r'bytes=(\d*)-(\d*)$', range_header.strip())
        if not match:
            return super().send_head()
        try:
            f = open(path, 'rb')
        except OSError:
            self.send_error(404, 'File not found')
            return None
        size = os.fstat(f.fileno()).st_size
        start = int(match.group(1)) if match.group(1) else 0
        end = int(match.group(2)) if match.group(2) else size - 1
        end = min(end, size - 1)
        if start >= size or start > end:
            f.close()
            self.send_response(416)
            self.send_header('Content-Range', 'bytes */%d' % size)
            self.end_headers()
            return None
        self.send_response(206)
        self.send_header('Content-Type', self.guess_type(path))
        self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, size))
        self.send_header('Content-Length', str(end - start + 1))
        self.end_headers()
        self.range = (start, end)
        return f

    def copyfile(self, source, outputfile):
        if self.range is None:
            return super().copyfile(source, outputfile)
        start, end = self.range
        source.seek(start)
        remaining = end - start + 1
        while remaining > 0:
            chunk = source.read(min(64 * 1024, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            remaining -= len(chunk)


def main():
    directory = sys.argv[1] if len(sys.argv) > 1 else '.'
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8123
    handler = functools.partial(RangeCORSHandler, directory=directory)
    server = http.server.ThreadingHTTPServer(('0.0.0.0', port), handler)
    print('Serving %s on 0.0.0.0:%d (CORS + Range)' % (directory, port))
    server.serve_forever()


if __name__ == '__main__':
    main()
