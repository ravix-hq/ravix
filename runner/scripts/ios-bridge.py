"""Private idb 1.5.2 bridge: framed stdout video and bounded stdin HID events.

Only the owned companion Unix socket is accepted. Raw idb H.264 carries no PTS;
frame timestamps are monotonic arrival times, not capture-latency measurements.
"""
import asyncio
import importlib.metadata
import json
import logging
import math
import os
import struct
import sys
import time
from idb.grpc.client import Client
from idb.common.types import DomainSocketAddress, VideoFormat, HIDPress, HIDTouch, HIDDirection, Point, HIDButtonType
from idb.common.hid import text_to_events, key_press_to_events, button_press_to_events, swipe_to_events

MAX_FRAME = 2 * 1024 * 1024

def emit(kind, data):
    if len(data) > MAX_FRAME:
        raise ValueError('Video payload exceeds limit')
    sys.stdout.buffer.write(struct.pack('>BI', kind, len(data)) + data)
    sys.stdout.buffer.flush()

async def main():
    if importlib.metadata.version('fb-idb') != '1.5.2':
        raise ValueError('Expected fb-idb 1.5.2')
    socket, udid = sys.argv[1:]
    if not socket.startswith('/private/tmp/') and not socket.startswith(os.environ['HOME'] + '/'):
        raise ValueError('Use the owned companion socket')
    logger = logging.getLogger('switchyard.idb')
    async with Client.build(DomainSocketAddress(path=socket), logger, exchange_metadata=False) as client:
        info = await client.describe()
        if info.udid.lower() != udid.lower() or not info.screen_dimensions:
            raise ValueError('Companion device identity mismatch')
        d = info.screen_dimensions
        width, height = d.width_points, d.height_points
        if not width or not height or not (0 < width <= 4096 and 0 < height <= 4096):
            raise ValueError('Missing simulator point dimensions')
        emit(1, json.dumps({'widthPoints': width, 'heightPoints': height, 'udid': udid}).encode())
        reader = asyncio.StreamReader(limit=4096)
        await asyncio.get_running_loop().connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
        async def events():
            down = False
            point = Point(0, 0)
            try:
                while line := await reader.readline():
                    if len(line) > 4096:
                        raise ValueError('Input line exceeds limit')
                    value = json.loads(line)
                    kind = value.get('type')
                    if kind in ('touch', 'scroll'):
                        x, y = value.get('x'), value.get('y')
                        if not all(isinstance(n, (int, float)) and math.isfinite(n) and 0 <= n <= 1 for n in (x, y)):
                            raise ValueError('Invalid input position')
                        point = Point(x * (width - 1), y * (height - 1))
                    if kind == 'touch':
                        action = value.get('action')
                        if action == 'down':
                            if down: raise ValueError('Touch already active')
                            down = True
                        elif action == 'move':
                            if not down: continue
                        elif action in ('up', 'cancel'):
                            if not down: continue
                            down = False
                        else: raise ValueError('Invalid touch action')
                        yield HIDPress(action=HIDTouch(point), direction=HIDDirection.DOWN if down else HIDDirection.UP)
                    elif kind == 'text':
                        text = value.get('text')
                        if not isinstance(text, str) or not 0 < len(text.encode()) <= 300 or any(ord(c) < 32 or ord(c) > 126 for c in text):
                            raise ValueError('iOS text input supports printable ASCII')
                        for event in text_to_events(text): yield event
                    elif kind == 'key':
                        key = value.get('key')
                        if key == 'home': items = button_press_to_events(HIDButtonType.HOME)
                        elif key in ('enter', 'backspace'): items = key_press_to_events({'enter':40, 'backspace':42}[key])
                        else: raise ValueError('Unsupported iOS key')
                        for event in items: yield event
                    elif kind == 'scroll':
                        delta = value.get('delta')
                        if not isinstance(delta, (int, float)) or not math.isfinite(delta) or abs(delta) > 16 or down:
                            raise ValueError('Invalid scroll')
                        end = (point.x, max(1, min(height - 2, point.y + delta * 40)))
                        for event in swipe_to_events((point.x, point.y), end, duration=0.2): yield event
                    else: raise ValueError('Unsupported input')
            finally:
                if down: yield HIDPress(action=HIDTouch(point), direction=HIDDirection.UP)
        async def video():
            async for data in client.stream_video(output_file=None, fps=30, format=VideoFormat.H264, compression_quality=0.5, scale_factor=0.5):
                # idb 1.1.8 emits one complete Annex-B access unit per gRPC data
                # response, including SPS/PPS on an IDR frame.
                emit(2, struct.pack('>Q', time.monotonic_ns() // 1000) + data)
        tasks = [asyncio.create_task(video()), asyncio.create_task(client.hid(events()))]
        try:
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done: await task
        finally:
            for task in tasks: task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

if __name__ == '__main__':
    try: asyncio.run(main())
    except (KeyboardInterrupt, BrokenPipeError): pass
