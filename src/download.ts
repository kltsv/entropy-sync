import { get as httpGet } from 'node:http';
import { get as httpsGet } from 'node:https';

/** Native HTTP avoids renderer CORS. Limits cover redirects, time and bytes. */
export function downloadBytes(url: string, signal: AbortSignal, redirects = 0): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    if (!['https:', 'http:'].includes(parsed.protocol) || redirects > 5) {
      reject(new Error('Invalid download URL or too many redirects.')); return;
    }
    const get = parsed.protocol === 'https:' ? httpsGet : httpGet;
    const request = get(parsed, { signal }, (response) => {
      const status = response.statusCode ?? 0;
      if ([301, 302, 303, 307, 308].includes(status) && response.headers.location) {
        const next = new URL(response.headers.location, parsed);
        response.resume();
        if (parsed.protocol === 'https:' && next.protocol !== 'https:') {
          reject(new Error('Refusing HTTPS downgrade.')); return;
        }
        resolve(downloadBytes(next.href, signal, redirects + 1)); return;
      }
      if (status !== 200) { response.resume(); reject(new Error(`Download failed: HTTP ${status}.`)); return; }
      const chunks: Buffer[] = [];
      let size = 0;
      response.on('data', (chunk: Buffer) => {
        size += chunk.length;
        if (size > 128 * 1024 * 1024) response.destroy(new Error('Download exceeds 128 MiB.'));
        else chunks.push(chunk);
      });
      response.on('end', () => resolve(Buffer.concat(chunks)));
      response.on('error', reject);
    });
    request.on('error', reject);
    request.setTimeout(30_000, () => request.destroy(new Error('Download timed out.')));
  });
}
