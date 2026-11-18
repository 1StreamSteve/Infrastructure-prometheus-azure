#!/usr/bin/env python3
"""SMTP sink for the test rig: accepts every message on 127.0.0.1:2525 and
saves it as /var/lib/rig/mail/<epoch>-<n>.eml. Nothing is relayed anywhere."""
import os, time, itertools
from aiosmtpd.controller import Controller

MAIL = '/var/lib/rig/mail'
SEQ = itertools.count(1)


class Sink:
    async def handle_DATA(self, server, session, envelope):
        os.makedirs(MAIL, exist_ok=True)
        path = os.path.join(MAIL, f'{time.time():.3f}-{next(SEQ)}.eml')
        with open(path, 'wb') as f:
            f.write(b'X-Rig-Rcpt: ' + ', '.join(envelope.rcpt_tos).encode() + b'\r\n')
            f.write(envelope.original_content or envelope.content)
        return '250 OK'


if __name__ == '__main__':
    c = Controller(Sink(), hostname='127.0.0.1', port=2525)
    c.start()
    print('rig smtp sink on 127.0.0.1:2525', flush=True)
    while True:
        time.sleep(3600)
